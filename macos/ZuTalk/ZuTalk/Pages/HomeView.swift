// HomeView.swift
// Research-led Home: the global Session ledger. Topic organization has its
// own first-level destination in `TopicsView`.

import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @ObservedObject private var activeCapture = ActiveBilingualTranscriptStore.shared
    @State private var isCreatingNotebook = false
    @State private var isStartingQuickCapture = false
    /// One editor instance serves both the Record button's language picker and
    /// the start flow. Sharing it means a language chosen in the picker is the
    /// language the recording starts with — the start path drains any queued
    /// picker edits before it snapshots the profile — and the persisted
    /// quick-capture profile is what makes the last selection the default.
    @State private var quickCaptureProfileEditor: NotebookCaptureProfileEditorModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if shouldShowSessionCatalog {
                    HomeSessionCatalog(
                        viewModel: viewModel,
                        onOpenSession: openSession,
                        onOpenTopic: openNotebook,
                        onStartRecording: startQuickRecording,
                        isStartingQuickCapture: isStartingQuickCapture,
                        activeCaptureDestination: activeCaptureDestination,
                        onReturnToActiveCapture: returnToActiveCapture,
                        onCreateTopic: { isCreatingNotebook = true },
                        quickCaptureLanguageEditor: quickCaptureProfileEditor
                    )
                }
            }
            .frame(maxWidth: 1_080, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.bgRoot)
        .sheet(isPresented: $isCreatingNotebook) {
            HomeCreateNotebookSheet { title in
                let created = viewModel.createNotebook(title: title)
                if created, let notebookId = viewModel.activeNotebookId {
                    // Enter the new Topic's Session workspace. Starting the
                    // microphone remains a separate, explicit action there.
                    DispatchQueue.main.async {
                        openNotebook(notebookId)
                    }
                }
                return created
            }
        }
        .onAppear {
            viewModel.loadSessions()
            viewModel.loadNotebookWorkspace()
            syncQuickCaptureProfileEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zutalkSessionUpdated)) { _ in
            viewModel.loadSessions()
            viewModel.loadNotebookWorkspace()
        }
        .montereyOnChange(of: viewModel.searchText) { _, _ in
            viewModel.updateTranscriptSearch()
        }
        .montereyOnChange(of: viewModel.quickCaptureNotebookId) { _, _ in
            syncQuickCaptureProfileEditor()
        }
        .montereyOnChange(of: activeCapture.isCaptureActive) { _, isActive in
            // A finished run may have advanced the profile revision (the start
            // itself commits the realtime authorization). Editing was locked
            // throughout, so reloading loses nothing and rebases the picker's
            // CAS revision onto whatever the run left behind.
            if isActive == false {
                quickCaptureProfileEditor?.load()
            }
        }
    }

    private var shouldShowSessionCatalog: Bool {
        viewModel.isLoadingSessions
            || viewModel.sessionLoadError != nil
            || viewModel.sessions.isEmpty == false
            || viewModel.notebooks.isEmpty == false
            || viewModel.canStartQuickCapture
    }

    private var activeCaptureDestination: HomeActiveCaptureDestination? {
        HomeRecordingEntryPolicy.activeDestination(
            isCaptureActive: activeCapture.isCaptureActive,
            captureNotebookId: activeCapture.notebookId,
            notebooks: viewModel.researchNotebooks
        )
    }

    private func openNotebook(_ notebookId: String) {
        viewModel.selectNotebook(notebookId)
        MainNavigationStore.shared.openTopicWorkspace(notebookID: notebookId)
    }

    private func openSession(_ sessionId: String) {
        viewModel.selectedId = sessionId
        MainNavigationStore.shared.openSession(sessionId)
    }

    private func syncQuickCaptureProfileEditor() {
        guard let notebookId = viewModel.quickCaptureNotebookId else {
            quickCaptureProfileEditor = nil
            return
        }
        guard quickCaptureProfileEditor?.notebookId != notebookId else { return }
        let editor = NotebookCaptureProfileEditorModel(notebookId: notebookId)
        editor.load()
        quickCaptureProfileEditor = editor
    }

    private func startQuickRecording() {
        guard isStartingQuickCapture == false,
              activeCapture.isCaptureActive == false,
              let notebookId = viewModel.quickCaptureNotebookId else {
            if activeCapture.isCaptureActive {
                returnToActiveCapture()
            } else {
                ToastCenter.shared.error(String(localized: "capture.route.unavailable"))
            }
            return
        }
        guard let startLease = NotebookCaptureStartWorkflowGate.shared.acquire() else {
            ToastCenter.shared.warning(String(localized: "capture.toast.start_failed"))
            return
        }
        isStartingQuickCapture = true
        Task { @MainActor in
            defer {
                NotebookCaptureStartWorkflowGate.shared.release(startLease)
                isStartingQuickCapture = false
            }
            // Start on the same editor the language picker edits, so queued
            // picker changes are committed by the start's own drain instead of
            // being lost to a second, freshly loaded instance.
            let profileEditor: NotebookCaptureProfileEditorModel
            if let shared = quickCaptureProfileEditor, shared.notebookId == notebookId {
                profileEditor = shared
                // A load or save that failed transiently would otherwise block
                // the start; retry is a no-op in the healthy states.
                profileEditor.retry()
            } else {
                profileEditor = NotebookCaptureProfileEditorModel(notebookId: notebookId)
                profileEditor.load()
            }
            do {
                let inviteSession = CommunityInviteSession.shared
                let preparation = try await NotebookCaptureStartPreparationWorkflow.prepare(
                    enableRealtimeIfNeeded: HomeRecordingEntryPolicy
                        .shouldEnableRealtimeForQuickCapture(
                            inviteIsEnabled: inviteSession.isEnabled,
                            inviteIsActive: inviteSession.isActive
                        ),
                    prepareProfile: { inviteRealtimeAuthorized in
                        try await profileEditor.prepareForHomeQuickCaptureStart(
                            inviteRealtimeAuthorized: inviteRealtimeAuthorized
                        )
                        return profileEditor.draft
                    },
                    prepareRealtimeCredential: { laneCount in
                        try await inviteSession.prepareRealtimeCredential(laneCount: laneCount)
                    }
                )
                if preparation == .personalKeyFallback {
                    ToastCenter.shared.info(
                        String(localized: "community_invite.fallback_personal_key")
                    )
                }
                try await NotebookCaptureStartCoordinator(
                    capture: activeCapture,
                    navigation: MainNavigationStore.shared
                ).start(notebookId: notebookId)
            } catch {
                // Return any invite reservation made during preparation before
                // surfacing the stage-specific, localized failure to the user.
                await CommunityInviteSession.shared.settleRealtimeSession(usedSeconds: 0)
                ToastCenter.shared.error(
                    String(localized: "capture.toast.start_failed"),
                    detail: error.localizedDescription
                )
            }
        }
    }

    private func returnToActiveCapture() {
        // Do not select the currently browsed Topic here. Capture routing owns
        // the authoritative active Topic and Session and must win over Home's
        // filter or last-browsed context.
        MainNavigationStore.shared.openActiveNotebookForCapture()
    }

    private func reloadWorkspace() {
        viewModel.loadSessions()
        viewModel.loadNotebookWorkspace()
    }
}

// MARK: - Topics

struct TopicsView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var searchText = ""
    @State private var isCreatingNotebook = false

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 340), spacing: Spacing.md)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(localized: "home.library.title"))
                            .font(.titleLG)
                            .foregroundColor(.textPrimary)
                            .accessibilityAddTraits(.isHeader)

                        Text(String(localized: "home.library.subtitle"))
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                    }

                    Spacer(minLength: Spacing.md)

                    Button {
                        isCreatingNotebook = true
                    } label: {
                        Label(String(localized: "home.notebook.new"), systemImage: "plus")
                            .font(.bodyMedium)
                            .padding(.horizontal, Spacing.md)
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.bgSunken)
                    .background(Color.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    .accessibilityIdentifier("topics.create")
                }

                TextField(
                    String(localized: "topics.search.placeholder"),
                    text: $searchText
                )
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, Spacing.md)
                .frame(minHeight: 44)
                .background(Color.bgSunken.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(Color.borderGhost.opacity(0.65), lineWidth: Stroke.thin)
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .accessibilityIdentifier("topics.search")

                if viewModel.notebookWorkspaceError != nil,
                   viewModel.hasNoResearchTopics {
                    HomeWorkspaceFailureView(onRetry: reload)
                } else if viewModel.hasNoResearchTopics {
                    HomeNoNotebookView {
                        isCreatingNotebook = true
                    }
                } else if filteredTopics.isEmpty {
                    EmptyState(
                        icon: "magnifyingglass",
                        title: String(localized: "topics.search.empty.title"),
                        description: String(localized: "topics.search.empty.description")
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.md) {
                        ForEach(filteredTopics, id: \.id) { notebook in
                            HomeNotebookCard(
                                notebook: notebook,
                                sessionCount: viewModel.notebookSessionCounts[notebook.id] ?? 0,
                                onOpen: { openTopic(notebook.id) }
                            )
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

private struct HomeNotebookCard: View {
    let notebook: FfiNotebook
    let sessionCount: Int
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack(alignment: .top) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.brandAccent)
                        .frame(width: 36, height: 36)
                        .background(Color.bgElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isHovering ? .textPrimary : .textTertiary)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(notebook.title)
                        .font(.titleMD)
                        .foregroundColor(.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(metadata)
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                }

                Text(String(localized: "home.topic.workspace_contents"))
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)

                Label(
                    String(localized: "home.notebook.local_first"),
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundColor(.textTertiary)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
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
        .accessibilityLabel(notebook.title)
        .accessibilityHint(String(localized: "home.library.open_hint"))
        .accessibilityIdentifier("topics.card.\(notebook.id)")
    }

    private var metadata: String {
        String(
            format: String(localized: "home.library.session_count_format"),
            Int64(sessionCount)
        )
    }
}

// MARK: - Legacy active Notebook components

private struct HomeNotebookHero: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var capture: ActiveBilingualTranscriptStore
    let onOpenNotebook: () -> Void
    let onCreateNotebook: () -> Void

    private var activeNotebook: FfiNotebook? { viewModel.activeNotebook }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(String(localized: "home.notebook.current"))
                        .font(.captionMedium)
                        .tracking(0.8)
                        .foregroundColor(.textSecondary)

                    notebookPicker
                }
                .frame(maxWidth: 420, alignment: .leading)
                .layoutPriority(1)

                Spacer(minLength: Spacing.md)

                Button(action: onCreateNotebook) {
                    Label(
                        String(localized: "home.notebook.new"),
                        systemImage: "plus"
                    )
                    .font(.bodyMedium)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundColor(.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .contentShape(Rectangle())
                .fixedSize()
                .help(String(localized: "home.notebook.new.help"))
                .accessibilityIdentifier("home.notebook.new")
            }

            Rectangle()
                .fill(Color.borderGhost.opacity(0.55))
                .frame(height: Stroke.thin)

            MontereyHorizontalViewThatFits {
                HStack(alignment: .bottom, spacing: Spacing.xl) {
                    notebookSummary
                    Spacer(minLength: Spacing.lg)
                    notebookActions
                }
            } fallback: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    notebookSummary
                    notebookActions
                }
            }

            if capture.isCaptureActive {
                captureNotice
            }

            Label(
                String(localized: "home.notebook.local_first"),
                systemImage: "lock.shield.fill"
            )
            .font(.bodySM)
            .foregroundColor(.textSecondary)
            .accessibilityElement(children: .combine)
        }
        .padding(Spacing.lg)
        .background(Color.bgElevated.opacity(0.38))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.borderGhost.opacity(0.65), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private var notebookPicker: some View {
        Menu {
            ForEach(viewModel.notebooks, id: \.id) { notebook in
                Button {
                    viewModel.selectNotebook(notebook.id)
                } label: {
                    if notebook.id == viewModel.activeNotebookId {
                        Label(notebook.title, systemImage: "checkmark")
                    } else {
                        Text(notebook.title)
                    }
                }
            }

            Divider()

            Button(action: onCreateNotebook) {
                Label(String(localized: "home.notebook.new"), systemImage: "plus")
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.brandAccent)

                Text(activeNotebook?.title ?? String(localized: "home.notebook.none"))
                    .font(.titleLG)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.textSecondary)
            }
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityLabel(String(localized: "home.notebook.switch"))
        .accessibilityValue(activeNotebook?.title ?? "")
        .accessibilityIdentifier("home.notebook.picker")
    }

    private var notebookSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "home.notebook.description"))
                .font(.bodyLG)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "home.notebook.description.detail"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var notebookActions: some View {
        HomeActionButton(
            title: openActionTitle,
            icon: capture.isCaptureActive ? captureStateIcon : "arrow.right",
            style: .primary,
            action: onOpenNotebook
        )
        .accessibilityIdentifier("home.notebook.open")
    }

    private var openActionTitle: String {
        capture.isCaptureActive
            ? String(localized: "home.capture.return")
            : String(localized: "home.notebook.open")
    }

    private var captureNotice: some View {
        let belongsToSelectedNotebook = capture.notebookId == viewModel.activeNotebookId
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(captureStateText, systemImage: captureStateIcon)
                .foregroundColor(.textPrimary)

            Text(
                belongsToSelectedNotebook
                    ? String(localized: "home.capture.owner_here")
                    : String(localized: "home.capture.owner_elsewhere")
            )
            .foregroundColor(.textSecondary)

            Label(remoteHealthText, systemImage: remoteHealthIcon)
                .foregroundColor(remoteHealthColor)
        }
        .font(.bodyMedium)
        .accessibilityElement(children: .combine)
    }

    private var captureStateText: String {
        switch capture.presentationCaptureState {
        case .recording: String(localized: "capture.state.recording")
        case .paused: String(localized: "capture.state.paused")
        case .draining: String(localized: "capture.state.draining")
        case .completed: String(localized: "capture.state.completed")
        case .interrupted: String(localized: "capture.state.interrupted")
        case .failed: String(localized: "capture.state.failed")
        }
    }

    private var captureStateIcon: String {
        switch capture.presentationCaptureState {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .draining: "hourglass.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var remoteHealthText: String {
        if let lagMs = capture.realtimeLagMs, lagMs >= 1_000 {
            return String(
                format: String(localized: "capture.remote.catching_up"),
                Int((lagMs + 999) / 1_000)
            )
        }
        return switch capture.remoteHealth {
        case .off: String(localized: "capture.remote.off")
        case .connecting: String(localized: "capture.remote.connecting")
        case .live: String(localized: "capture.remote.live")
        case .degraded: String(localized: "capture.remote.degraded")
        case .unavailable: String(localized: "capture.remote.unavailable")
        }
    }

    private var remoteHealthIcon: String {
        switch capture.remoteHealth {
        case .off: "lock.shield.fill"
        case .connecting: "network"
        case .live: "waveform.path"
        case .degraded: "exclamationmark.triangle.fill"
        case .unavailable: "wifi.slash"
        }
    }

    private var remoteHealthColor: Color {
        switch capture.remoteHealth {
        case .degraded, .unavailable: .signalAmber
        case .off, .connecting, .live: .textSecondary
        }
    }
}

private struct HomeNoNotebookView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "book.closed")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.textSecondary)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text(String(localized: "home.no_notebook.title"))
                    .font(.titleLG)
                    .foregroundColor(.textPrimary)

                Text(String(localized: "home.no_notebook.description"))
                    .font(.body)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HomeActionButton(
                title: String(localized: "home.first_use.action"),
                icon: "plus",
                style: .primary,
                action: onCreate
            )
            .accessibilityIdentifier("home.notebook.create_first")

            Label(
                String(localized: "home.notebook.local_first"),
                systemImage: "lock.shield.fill"
            )
            .font(.bodySM)
            .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(Spacing.xl)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.borderGhost.opacity(0.45), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }
}

private struct HomeWorkspaceFailureView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundColor(.signalAmber)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text(String(localized: "home.workspace.load_failed.title"))
                    .font(.titleLG)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "home.workspace.load_failed.description"))
                    .font(.body)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HomeActionButton(
                title: String(localized: "home.workspace.retry"),
                icon: "arrow.clockwise",
                style: .primary,
                action: onRetry
            )
            .accessibilityIdentifier("home.workspace.retry")
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .padding(Spacing.xl)
    }
}

private struct HomeWorkspaceRefreshWarning: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Label(
                String(localized: "home.workspace.refresh_failed"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.bodySM)
            .foregroundColor(.signalAmber)

            Spacer()

            Button(String(localized: "home.workspace.retry"), action: onRetry)
                .buttonStyle(.plain)
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("home.workspace.retry")
        }
        .padding(.horizontal, Spacing.md)
        .background(Color.bgElevated.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}

// MARK: - Global Session catalogue

private struct HomeSessionCatalog: View {
    @ObservedObject var viewModel: LibraryViewModel
    let onOpenSession: (String) -> Void
    let onOpenTopic: (String) -> Void
    let onStartRecording: () -> Void
    let isStartingQuickCapture: Bool
    let activeCaptureDestination: HomeActiveCaptureDestination?
    let onReturnToActiveCapture: () -> Void
    let onCreateTopic: () -> Void
    let quickCaptureLanguageEditor: NotebookCaptureProfileEditorModel?
    @FocusState private var isSearchFocused: Bool

    private var groups: [SessionGroup] { viewModel.catalogGroupedSessions }
    private var sessions: [SessionListItem] { viewModel.catalogSessions }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            catalogHeader

            MontereyHorizontalViewThatFits {
                HStack(spacing: Spacing.md) {
                    compactSearch
                    Spacer(minLength: Spacing.sm)
                    catalogMetrics
                }
            } fallback: {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    compactSearch
                    HStack(spacing: Spacing.md) {
                        catalogMetrics
                        Spacer(minLength: 0)
                    }
                }
            }

            HomeTopicFilterBar(viewModel: viewModel)

            if viewModel.hasLoadedTopicMemberships == false,
               viewModel.notebookWorkspaceError != nil {
                HomeCatalogRefreshWarning(
                    message: String(localized: "home.workspace.membership_unavailable"),
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
                        isSearchFocused = true
                    }
                } else if viewModel.selectedTopicFilterId
                    == LibraryViewModel.unfiledTopicFilterId {
                    HomeCatalogEmptyState(
                        title: String(localized: "home.catalog.unfiled_empty.title"),
                        description: String(localized: "home.catalog.unfiled_empty.description"),
                        icon: "tray"
                    )
                } else if viewModel.selectedTopicFilterId != nil {
                    HomeCatalogEmptyState(
                        title: String(localized: "home.catalog.topic_empty.title"),
                        description: String(localized: "home.catalog.topic_empty.description"),
                        icon: "folder"
                    )
                } else {
                    HomeCatalogEmptyState(
                        title: String(localized: "home.catalog.empty.title"),
                        description: String(localized: "home.catalog.empty.description"),
                        icon: "waveform"
                    )
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

    private var catalogHeader: some View {
        MontereyHorizontalViewThatFits {
            HStack(alignment: .top, spacing: Spacing.md) {
                catalogIdentity
                    .layoutPriority(1)
                Spacer(minLength: Spacing.md)
                catalogActions
                    .fixedSize()
            }

        } fallback: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                catalogIdentity
                catalogActions
            }
        }
    }

    private var catalogIdentity: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "home.catalog.title"))
                .font(.titleLG)
                .foregroundColor(.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "home.catalog.subtitle"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var catalogActions: some View {
        MontereyHorizontalViewThatFits {
            HStack(spacing: Spacing.sm) {
                quickCaptureLanguageAction
                recordingAction
                secondaryCatalogActions
            }
        } fallback: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                quickCaptureLanguageAction
                recordingAction
                secondaryCatalogActions
            }
        }
    }

    /// The capture languages, surfaced beside Record so a multi-language
    /// session starts in one click. Hidden while a capture is active: the
    /// button next door is then "return to recording" and the profile is
    /// locked anyway.
    @ViewBuilder
    private var quickCaptureLanguageAction: some View {
        if activeCaptureDestination == nil, let editor = quickCaptureLanguageEditor {
            HomeQuickCaptureLanguagePicker(editor: editor)
        }
    }

    @ViewBuilder
    private var recordingAction: some View {
            if let activeCaptureDestination {
                Button(action: onReturnToActiveCapture) {
                    Label(
                        activeCaptureButtonTitle(activeCaptureDestination),
                        systemImage: "record.circle.fill"
                    )
                    .font(.bodyMedium)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundColor(.signalGreen)
                .padding(.horizontal, Spacing.md)
                .background(Color.signalGreen.opacity(0.1))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.signalGreen.opacity(0.28), lineWidth: Stroke.thin)
                )
                .clipShape(Capsule())
                .help(activeCaptureButtonTitle(activeCaptureDestination))
                .accessibilityIdentifier("home.catalog.record")
            } else {
                Button(action: onStartRecording) {
                    Label(
                        isStartingQuickCapture
                            ? String(localized: "home.record.starting")
                            : String(localized: "home.record.start"),
                        systemImage: isStartingQuickCapture ? "ellipsis" : "record.circle"
                    )
                    .font(.bodyMedium)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundColor(.signalRed)
                .padding(.horizontal, Spacing.md)
                .background(Color.signalRed.opacity(0.1))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.signalRed.opacity(0.3), lineWidth: Stroke.thin)
                )
                .clipShape(Capsule())
                .disabled(isStartingQuickCapture || viewModel.canStartQuickCapture == false)
                .help(String(localized: viewModel.canStartQuickCapture
                    ? "home.record.start_hint"
                    : "home.record.unavailable_hint"))
                .accessibilityHint(Text(String(localized: viewModel.canStartQuickCapture
                    ? "home.record.start_hint"
                    : "home.record.unavailable_hint")))
                .accessibilityIdentifier("home.catalog.record")
            }
    }

    private var secondaryCatalogActions: some View {
        Button(action: onCreateTopic) {
            Label(String(localized: "home.notebook.new"), systemImage: "plus")
                .font(.bodyMedium)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundColor(.textPrimary)
        .accessibilityIdentifier("home.notebook.new")
    }

    @ViewBuilder
    private var catalogMetrics: some View {
        Text(
            String(
                format: String(localized: "home.catalog.count_format"),
                Int64(sessions.count)
            )
        )
        .font(.bodySM)
        .foregroundColor(.textSecondary)
        .monospacedDigit()

        if viewModel.isSearchingTranscripts {
            ProgressView()
                .controlSize(.small)
                .help(String(localized: "home.catalog.searching_transcripts"))
                .accessibilityLabel(String(localized: "home.catalog.searching_transcripts"))
        }

        if let topicId = viewModel.selectedTopicFilterId,
           topicId != LibraryViewModel.unfiledTopicFilterId {
            Button {
                onOpenTopic(topicId)
            } label: {
                Label(String(localized: "home.library.open_hint"), systemImage: "arrow.up.right")
                    .font(.bodyMedium)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .foregroundColor(.textPrimary)
            .accessibilityIdentifier("home.topic.open_selected")
        }
    }

    private func activeCaptureButtonTitle(
        _ destination: HomeActiveCaptureDestination
    ) -> String {
        String(
            format: String(localized: "home.record.return_active_format"),
            destination.topicTitle ?? String(localized: "home.record.unfiled")
        )
    }

    private var compactSearch: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.textSecondary)

            TextField(
                String(localized: "home.catalog.search_placeholder"),
                text: $viewModel.searchText
            )
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundColor(.textPrimary)
            .focused($isSearchFocused)
            .accessibilityIdentifier("home.catalog.search")

            if viewModel.hasCatalogSearchText {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.textSecondary)
                }
                .buttonStyle(.plain)
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
    }
}

private struct HomeCatalogSearchingState: View {
    var body: some View {
        HStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "home.catalog.searching_transcripts"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(Color.bgElevated.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityElement(children: .combine)
    }
}

private struct HomeCatalogLoadFailureState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.bodySM)
                .foregroundColor(.signalAmber)

            HomeActionButton(
                title: String(localized: "home.workspace.retry"),
                icon: "arrow.clockwise",
                style: .secondary,
                action: onRetry
            )
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(Color.bgElevated.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityIdentifier("home.catalog.load_failure")
    }
}

private struct HomeCatalogRefreshWarning: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.bodySM)
                .foregroundColor(.signalAmber)

            Spacer(minLength: 0)

            Button(String(localized: "home.workspace.retry"), action: onRetry)
                .buttonStyle(.plain)
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
                .frame(minHeight: 36)
        }
        .padding(.horizontal, Spacing.md)
        .background(Color.bgElevated.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityIdentifier("home.catalog.refresh_warning")
    }
}

private struct HomeCatalogLoadingState: View {
    var body: some View {
        HStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.small)

            Text(String(localized: "home.catalog.loading"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)

            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(Color.bgElevated.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityElement(children: .combine)
    }
}

private struct HomeTopicFilterBar: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                HomeTopicFilterChip(
                    title: String(localized: "home.catalog.filter.all"),
                    count: viewModel.sessions.count,
                    isSelected: viewModel.selectedTopicFilterId == nil,
                    action: { viewModel.selectTopicFilter(nil) }
                )
                .accessibilityIdentifier("home.topic.filter.all")

                if viewModel.hasLoadedTopicMemberships {
                    HomeTopicFilterChip(
                        title: String(localized: "home.row.topic.unassigned"),
                        count: viewModel.unfiledSessionCount,
                        isSelected: viewModel.selectedTopicFilterId
                            == LibraryViewModel.unfiledTopicFilterId,
                        action: viewModel.selectUnfiledFilter
                    )
                    .accessibilityIdentifier("home.topic.filter.unfiled")
                }

                ForEach(viewModel.researchNotebooks, id: \.id) { notebook in
                    HomeTopicFilterChip(
                        title: notebook.title,
                        count: viewModel.notebookSessionCounts[notebook.id] ?? 0,
                        isSelected: viewModel.selectedTopicFilterId == notebook.id,
                        action: { viewModel.selectTopicFilter(notebook.id) }
                    )
                    .accessibilityIdentifier("home.topic.filter.\(notebook.id)")
                }
            }
        }
        .accessibilityIdentifier("home.topic.filters")
    }
}

private struct HomeTopicFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Text(title)
                    .lineLimit(1)

                Text("\(count)")
                    .monospacedDigit()
                    .foregroundColor(isSelected ? .brandAccentForeground.opacity(0.82) : .textTertiary)
            }
            .font(.bodySM)
            .foregroundColor(isSelected ? .brandAccentForeground : .textSecondary)
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 34)
            .background(isSelected ? Color.brandAccent : Color.bgElevated.opacity(0.32))
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.brandAccent : Color.borderGhost.opacity(0.55),
                        lineWidth: Stroke.thin
                    )
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HomeCatalogEmptyState: View {
    let title: String
    let description: String
    let icon: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.textSecondary)
                .frame(width: 40, height: 40)
                .background(Color.bgElevated.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)

                Text(description)
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(Color.bgElevated.opacity(0.2))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.borderGhost.opacity(0.45), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }
}

private struct HomeNoSearchResults: View {
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "home.catalog.no_match.title"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "home.catalog.no_match.description"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            HomeActionButton(
                title: String(localized: "home.catalog.search.clear"),
                icon: "xmark",
                style: .secondary,
                action: onClear
            )
        }
        .padding(Spacing.lg)
        .background(Color.bgElevated.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
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
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(session.timeString)
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                            .monospacedDigit()

                        Image(systemName: rowIcon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(rowIconColor)
                            .accessibilityHidden(true)
                    }
                    .frame(width: 58, alignment: .leading)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.sm) {
                            Text(titleForDisplay)
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)

                            if let status = statusLabel {
                                Label(status.text, systemImage: status.icon)
                                    .font(.captionMedium)
                                    .foregroundColor(status.color)
                            }
                        }

                        if session.preview.isEmpty == false {
                            Text(session.preview)
                                .font(.bodySM)
                                .foregroundColor(.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let placeholder = previewPlaceholder {
                            Text(placeholder.text)
                                .font(.bodySM)
                                .foregroundColor(placeholder.color)
                                .italic()
                        }

                        metadata
                    }

                    Spacer(minLength: Spacing.sm)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .padding(.top, Spacing.xs)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xsm)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(canOpen == false)
            .focusable()
            .focused($isFocused)
            .focusRing(isFocused, cornerRadius: Radius.sm)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(
                String(localized: membershipKnown == false
                    ? "home.catalog.row.membership_unknown_hint"
                    : topicTitle == nil && canOpen
                        ? "home.catalog.row.open_unfiled_hint"
                        : canOpen ? "home.catalog.row.open_hint" : "home.catalog.row.unfiled_hint")
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.brandAccent)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(String(localized: "home.row.assign_to_topic"))
                .accessibilityLabel(String(localized: "home.row.assign_to_topic"))
            }

            Menu {
                // 正在录的删不了(Core 软删与彻底删除都拒绝)。禁用而不是
                // 藏起来 —— 按钮消失了用户会以为是别的毛病,禁用配一句
                // 原因才说得清「等录完」。
                Button(role: .destructive, action: onDelete) {
                    Label(String(localized: "common.delete"), systemImage: "trash")
                }
                .disabled(session.isRecording)

                if session.isRecording {
                    Text(String(localized: "home.recording.delete_while_recording"))
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textSecondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(
                String(format: String(localized: "home.catalog.row.actions_format"), titleForDisplay)
            )
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
    }

    private var metadata: some View {
        HStack(spacing: Spacing.sm) {
            Label(
                membershipLabel,
                systemImage: "folder"
            )
            .lineLimit(1)
            .frame(maxWidth: 180, alignment: .leading)

            if session.durationString.isEmpty == false,
               session.durationString != "00:00" {
                Text("·")
                Text(session.durationString)
            }

            if session.languagePair.isEmpty == false,
               session.languagePair != "—" {
                Text("·")
                Text(session.languagePair)
            }

            Text("·")

            Label(sessionKindLabel, systemImage: sessionKindIcon)
        }
        .font(.captionMedium)
        .foregroundColor(.textSecondary)
    }

    private var sessionKindLabel: String {
        session.sessionType == "import"
            ? String(localized: "home.row.kind.import")
            : String(localized: "home.row.kind.recording")
    }

    private var membershipLabel: String {
        guard membershipKnown else {
            return String(localized: "home.row.topic.unknown")
        }
        return topicTitle ?? String(localized: "home.row.topic.unassigned")
    }

    private var sessionKindIcon: String {
        session.sessionType == "import" ? "square.and.arrow.down" : "mic.fill"
    }

    private var titleForDisplay: String {
        let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "home.catalog.row.untitled")
            : trimmed
    }

    private var rowIcon: String {
        session.homeStatusState == .recording
            ? "waveform.circle.fill"
            : "waveform"
    }

    private var rowIconColor: Color {
        session.homeStatusState == .recording
            ? .accentOrange
            : .textSecondary
    }

    private var statusLabel: (text: String, color: Color, icon: String)? {
        switch session.homeStatusState {
        case .recording:
            return (
                String(localized: "home.row.preview.recording"),
                .accentOrange,
                "record.circle.fill"
            )
        case .transcribing:
            return (
                String(localized: "home.row.preview.pending"),
                .signalAmber,
                "hourglass"
            )
        case .interrupted:
            return (
                String(localized: "home.row.status.interrupted"),
                .signalAmber,
                "exclamationmark.circle.fill"
            )
        case .failed:
            return (
                String(localized: "home.row.preview.failed"),
                .destructive,
                "exclamationmark.triangle.fill"
            )
        case .completed:
            return (
                String(localized: "home.row.status.completed"),
                .signalGreen,
                "checkmark.circle.fill"
            )
        case .imported:
            return (
                String(localized: "home.row.status.imported"),
                .textPrimary,
                "square.and.arrow.down"
            )
        case .none:
            return nil
        }
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
        parts.append(membershipLabel)
        parts.append(sessionKindLabel)
        if session.durationString.isEmpty == false {
            parts.append(session.durationString)
        }
        if session.languagePair.isEmpty == false, session.languagePair != "—" {
            parts.append(session.languagePair)
        }
        if let statusLabel {
            parts.append(statusLabel.text)
        }
        if session.preview.isEmpty == false {
            parts.append(session.preview)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Quick-capture language picker

/// Exposes the capture languages on Home, beside Record. It edits the same
/// persisted quick-capture profile the start flow reads, so the previous
/// selection is the default and a change here is what the next one-click
/// recording uses — including two- and three-language sessions.
private struct HomeQuickCaptureLanguagePicker: View {
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    @State private var isPresentingEditor = false
    @State private var languageSearch = ""

    private var languages: [(code: String, label: String)] {
        NotebookCaptureSupportedLanguages.options()
    }

    private var selectedLanguages: [String] { editor.draft.selectedLanguages }

    var body: some View {
        Button {
            isPresentingEditor = true
        } label: {
            Label(compactSelectionTitle, systemImage: "character.bubble")
                .font(.bodyMedium)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundColor(.textPrimary)
        .padding(.horizontal, Spacing.md)
        .background(Color.bgElevated.opacity(0.42))
        .overlay(
            Capsule()
                .strokeBorder(Color.borderGhost.opacity(0.3), lineWidth: Stroke.thin)
        )
        .clipShape(Capsule())
        .disabled(editor.canEdit == false)
        .opacity(editor.canEdit ? 1 : 0.58)
        .help(pickerHelp)
        .accessibilityLabel(Text(String(localized: "home.record.languages.picker")))
        .accessibilityValue(Text(fullSelectionNames))
        .accessibilityIdentifier("home.record.languages")
        .popover(isPresented: $isPresentingEditor, arrowEdge: .bottom) {
            editorPopover
        }
    }

    /// Short codes keep the control one glance wide in every UI language;
    /// the full localized names live in the tooltip and the popover.
    private var compactSelectionTitle: String {
        selectedLanguages.map { $0.uppercased() }.joined(separator: " · ")
    }

    private var fullSelectionNames: String {
        selectedLanguages.map(languageLabel).joined(separator: " · ")
    }

    private var pickerHelp: String {
        String(
            format: String(localized: "home.record.languages.picker_hint_format"),
            fullSelectionNames
        )
    }

    private var editorPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "capture.settings.languages.question"))
                .font(.captionMedium)
                .foregroundColor(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(String(localized: "capture.settings.languages.ordered_detail"))
                .font(.system(size: 10))
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal) {
                HStack(spacing: Spacing.sm) {
                    ForEach(Array(selectedLanguages.enumerated()), id: \.element) { index, language in
                        selectedLanguageChip(language: language, index: index)
                    }
                }
            }
            .montereyScrollIndicators(true)

            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.textTertiary)
                    .accessibilityHidden(true)
                TextField(
                    String(localized: "capture.settings.languages.search"),
                    text: $languageSearch
                )
                .textFieldStyle(.plain)
                .accessibilityLabel(Text(String(localized: "capture.settings.languages.search")))
            }
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: 36)
            .background(Color.bgSunken.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .strokeBorder(Color.borderGhost.opacity(0.3), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))

            if languageSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                suggestedLanguageResults
            } else {
                languageSearchResults
            }
        }
        .padding(Spacing.md)
        .frame(width: 360)
        .disabled(editor.canEdit == false)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var suggestedLanguageResults: some View {
        let selected = Set(selectedLanguages)
        let suggestions = NotebookCaptureSupportedLanguages.suggestedCodes()
            .filter { selected.contains($0) == false }
            .compactMap { code in languages.first { $0.code == code } }

        if selectedLanguages.count < NotebookCaptureSupportedLanguages.maximumSelectedCount,
           suggestions.isEmpty == false {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "capture.settings.languages.suggested"))
                    .font(.system(size: 10))
                    .foregroundColor(.textTertiary)
                addLanguageChipRow(suggestions)
            }
        }
    }

    private var languageSearchResults: some View {
        let query = languageSearch
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let selected = Set(selectedLanguages)
        let matches = languages.filter { language in
            selected.contains(language.code) == false
                && (language.code.localizedCaseInsensitiveContains(query)
                    || language.label.localizedCaseInsensitiveContains(query))
        }

        return Group {
            if selectedLanguages.count >= NotebookCaptureSupportedLanguages.maximumSelectedCount {
                Text(String(localized: "capture.settings.languages.maximum_reached"))
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .padding(.vertical, Spacing.xs)
            } else if matches.isEmpty {
                Text(String(localized: "capture.settings.languages.no_results"))
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .padding(.vertical, Spacing.xs)
            } else {
                addLanguageChipRow(matches)
            }
        }
    }

    private func addLanguageChipRow(
        _ options: [(code: String, label: String)]
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.xs) {
                ForEach(options, id: \.code) { language in
                    Button {
                        addLanguage(language.code)
                    } label: {
                        Label(language.label, systemImage: "plus")
                            .font(.caption)
                            .padding(.horizontal, Spacing.sm)
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.textPrimary)
                    .background(Color.bgElevated.opacity(0.42))
                    .clipShape(Capsule())
                    .accessibilityLabel(Text(String(
                        format: String(localized: "capture.settings.languages.add_format"),
                        language.label
                    )))
                }
            }
        }
        .montereyScrollIndicators(true)
    }

    private func selectedLanguageChip(language: String, index: Int) -> some View {
        HStack(spacing: 2) {
            Text(languageLabel(language))
                .font(.captionMedium)
                .foregroundColor(.textPrimary)
                .padding(.leading, Spacing.sm)
                .padding(.trailing, Spacing.xs)

            languageChipButton(
                systemImage: "chevron.left",
                label: String(localized: "capture.settings.languages.move_earlier"),
                disabled: index == 0,
                action: { moveLanguage(at: index, offset: -1) }
            )
            languageChipButton(
                systemImage: "chevron.right",
                label: String(localized: "capture.settings.languages.move_later"),
                disabled: index == selectedLanguages.count - 1,
                action: { moveLanguage(at: index, offset: 1) }
            )
            languageChipButton(
                systemImage: "xmark",
                label: String(localized: "capture.settings.languages.remove"),
                disabled: selectedLanguages.count <= 1,
                action: { removeLanguage(at: index) }
            )
        }
        .frame(minHeight: 36)
        .background(Color.bgElevated.opacity(0.42))
        .overlay(
            Capsule()
                .strokeBorder(Color.borderGhost.opacity(0.3), lineWidth: 0.5)
        )
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }

    private func languageChipButton(
        systemImage: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 28, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundColor(.textSecondary)
        .contentShape(Rectangle())
        .disabled(disabled)
        .accessibilityLabel(Text(label))
    }

    private func addLanguage(_ language: String) {
        guard selectedLanguages.count
                < NotebookCaptureSupportedLanguages.maximumSelectedCount,
              selectedLanguages.contains(language) == false
        else { return }
        editor.scheduleUpdate(.addLanguage(language))
        languageSearch = ""
    }

    private func removeLanguage(at index: Int) {
        guard selectedLanguages.count > 1,
              selectedLanguages.indices.contains(index)
        else { return }
        editor.scheduleUpdate(.removeLanguage(selectedLanguages[index]))
    }

    private func moveLanguage(at index: Int, offset: Int) {
        let destination = index + offset
        guard selectedLanguages.indices.contains(index),
              selectedLanguages.indices.contains(destination)
        else { return }
        editor.scheduleUpdate(.moveLanguage(selectedLanguages[index], offset: offset))
    }

    private func languageLabel(_ code: String) -> String {
        languages.first(where: { $0.code == code })?.label ?? code.uppercased()
    }
}

// MARK: - Creation and actions

private struct HomeCreateNotebookSheet: View {
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
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "home.create.title"))
                    .font(.titleLG)
                    .foregroundColor(.textPrimary)

                Text(String(localized: "home.create.description"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "home.create.name_label"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)

                TextField(
                    String(localized: "home.create.name_placeholder"),
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

            Label(
                String(localized: "home.create.local_first"),
                systemImage: "lock.shield.fill"
            )
            .font(.bodySM)
            .foregroundColor(.textSecondary)

            HStack(spacing: Spacing.sm) {
                Spacer()

                Button(String(localized: "common.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "home.create.action")) {
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
        .frame(width: 440)
        .background(Color.bgRoot)
        .onAppear { isTitleFocused = true }
    }
}

private enum HomeActionButtonStyle {
    case primary
    case secondary
}

private struct HomeActionButton: View {
    let title: String
    let icon: String
    let style: HomeActionButtonStyle
    var isLoading = false
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }

                Text(title)
                    .font(.bodyMedium)
                    .lineLimit(1)
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 44)
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(borderColor, lineWidth: Stroke.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false || isLoading)
        .focusable(isEnabled && isLoading == false)
        .focused($isFocused)
        .focusRing(isFocused, cornerRadius: Radius.sm)
        .onHover { isHovering = $0 && isEnabled && isLoading == false }
        .animation(Motion.microInteraction, value: isHovering)
        .accessibilityLabel(title)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .brandAccentForeground.opacity(isEnabled ? 1 : 0.45)
        case .secondary:
            return .textPrimary
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return isHovering ? .brandAccentHover : .brandAccent
        case .secondary:
            return isHovering
                ? Color.bgElevated.opacity(0.75)
                : Color.bgElevated.opacity(0.45)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return .clear
        case .secondary:
            return Color.borderGhost.opacity(0.65)
        }
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
