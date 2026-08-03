// HomeView.swift
// Notebook-first home for the local Zulangue MVP.

import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var isCreatingNotebook = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if viewModel.requiresNotebookBeforeRecording {
                    if viewModel.notebookWorkspaceError == nil {
                        HomeNoNotebookView {
                            isCreatingNotebook = true
                        }
                    } else {
                        HomeWorkspaceFailureView(onRetry: reloadWorkspace)
                    }
                } else {
                    HomeNotebookLibrary(
                        viewModel: viewModel,
                        onOpenNotebook: openNotebook,
                        onCreateNotebook: { isCreatingNotebook = true }
                    )

                    if viewModel.notebookWorkspaceError != nil {
                        HomeWorkspaceRefreshWarning(onRetry: reloadWorkspace)
                    }
                }
            }
            .frame(maxWidth: 1_080, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.bpBlue)
        .sheet(isPresented: $isCreatingNotebook) {
            HomeCreateNotebookSheet { title in
                let created = viewModel.createNotebook(title: title)
                if created, let notebookId = viewModel.activeNotebookId {
                    // The first successful action should lead straight to the
                    // recording surface instead of asking a novice to find and
                    // reopen the Notebook they just created.
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .zulangueSessionUpdated)) { _ in
            viewModel.loadSessions()
            viewModel.loadNotebookWorkspace()
        }
    }

    private func openNotebook(_ notebookId: String) {
        viewModel.selectNotebook(notebookId)
        MainNavigationStore.shared.openActiveNotebookForCapture()
    }

    private func reloadWorkspace() {
        viewModel.loadSessions()
        viewModel.loadNotebookWorkspace()
    }
}

// MARK: - Notebook library

private struct HomeNotebookLibrary: View {
    @ObservedObject var viewModel: LibraryViewModel
    let onOpenNotebook: (String) -> Void
    let onCreateNotebook: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 340), spacing: Spacing.md)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "home.library.title"))
                        .font(.titleLG)
                        .foregroundColor(.bpLine)

                    Text(String(localized: "home.library.subtitle"))
                        .font(.bodySM)
                        .foregroundColor(.textOnBpDim)
                }

                Spacer()

                Button(action: onCreateNotebook) {
                    Label(String(localized: "home.notebook.new"), systemImage: "plus")
                        .font(.bodyMedium)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundColor(.bpLine)
                .accessibilityIdentifier("home.notebook.new")
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.md) {
                ForEach(viewModel.notebooks, id: \.id) { notebook in
                    HomeNotebookCard(
                        notebook: notebook,
                        sessionCount: viewModel.notebookSessionCounts[notebook.id] ?? 0,
                        onOpen: { onOpenNotebook(notebook.id) }
                    )
                }
            }
        }
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
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.brandAccent)
                        .frame(width: 36, height: 36)
                        .background(Color.bpBlueChip)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isHovering ? .bpLine : .textOnBpFaint)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(notebook.title)
                        .font(.titleMD)
                        .foregroundColor(.bpLine)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(metadata)
                        .font(.bodySM)
                        .foregroundColor(.textOnBpDim)
                }

                Label(
                    String(localized: "home.notebook.local_first"),
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundColor(.textOnBpFaint)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(isHovering ? Color.bpBlueLight.opacity(0.58) : Color.bpBlueLight.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(
                        isHovering ? Color.brandAccent.opacity(0.45) : Color.bpLineGhost.opacity(0.55),
                        lineWidth: Stroke.thin
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(notebook.title)
        .accessibilityHint(String(localized: "home.library.open_hint"))
        .accessibilityIdentifier("home.notebook.card.\(notebook.id)")
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
    let onImportAudio: () -> Void
    let onCreateNotebook: () -> Void

    private var activeNotebook: FfiNotebook? { viewModel.activeNotebook }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(String(localized: "home.notebook.current"))
                        .font(.captionMedium)
                        .tracking(0.8)
                        .foregroundColor(.textOnBpDim)

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
                .foregroundColor(.textOnBpDim)
                .padding(.horizontal, Spacing.sm)
                .contentShape(Rectangle())
                .fixedSize()
                .help(String(localized: "home.notebook.new.help"))
                .accessibilityIdentifier("home.notebook.new")
            }

            Rectangle()
                .fill(Color.bpLineGhost.opacity(0.55))
                .frame(height: Stroke.thin)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: Spacing.xl) {
                    notebookSummary
                    Spacer(minLength: Spacing.lg)
                    notebookActions
                }

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
            .foregroundColor(.textOnBpDim)
            .accessibilityElement(children: .combine)
        }
        .padding(Spacing.lg)
        .background(Color.bpBlueLight.opacity(0.38))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.bpLineGhost.opacity(0.65), lineWidth: Stroke.thin)
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
                    .foregroundColor(.bpLine)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.textOnBpDim)
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
                .foregroundColor(.bpLine)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "home.notebook.description.detail"))
                .font(.bodySM)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var notebookActions: some View {
        HStack(spacing: Spacing.sm) {
            HomeActionButton(
                title: openActionTitle,
                icon: capture.isCaptureActive ? captureStateIcon : "arrow.right",
                style: .primary,
                action: onOpenNotebook
            )
            .accessibilityIdentifier("home.notebook.open")

            HomeActionButton(
                title: viewModel.isImportingAudio
                    ? String(localized: "home.import.in_progress")
                    : String(localized: "home.import.action"),
                icon: "square.and.arrow.down",
                style: .secondary,
                isLoading: viewModel.isImportingAudio,
                isEnabled: viewModel.isImportingAudio == false,
                action: onImportAudio
            )
            .accessibilityIdentifier("home.notebook.import")
        }
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
                .foregroundColor(.bpLine)

            Text(
                belongsToSelectedNotebook
                    ? String(localized: "home.capture.owner_here")
                    : String(localized: "home.capture.owner_elsewhere")
            )
            .foregroundColor(.textOnBpDim)

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
        case .off, .connecting, .live: .textOnBpDim
        }
    }
}

private struct HomeNoNotebookView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "book.closed")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(.textOnBpDim)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text(String(localized: "home.no_notebook.title"))
                    .font(.titleLG)
                    .foregroundColor(.bpLine)

                Text(String(localized: "home.no_notebook.description"))
                    .font(.body)
                    .foregroundColor(.textOnBpDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(alignment: .top, spacing: Spacing.md) {
                firstUseStep(
                    number: "1",
                    title: String(localized: "home.first_use.step1.title"),
                    detail: String(localized: "home.first_use.step1.detail")
                )
                firstUseStep(
                    number: "2",
                    title: String(localized: "home.first_use.step2.title"),
                    detail: String(localized: "home.first_use.step2.detail")
                )
                firstUseStep(
                    number: "3",
                    title: String(localized: "home.first_use.step3.title"),
                    detail: String(localized: "home.first_use.step3.detail")
                )
            }
            .frame(maxWidth: 720)

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
            .foregroundColor(.textOnBpDim)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .padding(Spacing.xl)
    }

    private func firstUseStep(number: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(number)
                .font(.captionMedium)
                .foregroundColor(.brandAccentForeground)
                .frame(width: 24, height: 24)
                .background(Color.brandAccent)
                .clipShape(Circle())

            Text(title)
                .font(.bodyMedium)
                .foregroundColor(.bpLine)

            Text(detail)
                .font(.bodySM)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(Color.bpBlueLight.opacity(0.3))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.bpLineGhost.opacity(0.55), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
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
                    .foregroundColor(.bpLine)
                Text(String(localized: "home.workspace.load_failed.description"))
                    .font(.body)
                    .foregroundColor(.textOnBpDim)
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
                .foregroundColor(.bpLine)
                .frame(minHeight: 44)
                .accessibilityIdentifier("home.workspace.retry")
        }
        .padding(.horizontal, Spacing.md)
        .background(Color.bpBlueLight.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}

// MARK: - Recent recordings

private struct HomeRecentRecordingsSection: View {
    @ObservedObject var viewModel: LibraryViewModel
    let onOpenSession: (String) -> Void
    @FocusState private var isSearchFocused: Bool

    private var groups: [SessionGroup] { viewModel.activeNotebookGroupedSessions }
    private var sessions: [SessionListItem] { viewModel.activeNotebookSessions }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .center, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "home.recent.title"))
                        .font(.titleMD)
                        .foregroundColor(.bpLine)

                    Text(
                        String(
                            format: String(localized: "home.recent.count_format"),
                            Int64(sessions.count)
                        )
                    )
                    .font(.bodySM)
                    .foregroundColor(.textOnBpDim)
                }

                Spacer(minLength: Spacing.md)

                if sessions.count >= 5 || viewModel.searchText.isEmpty == false {
                    compactSearch
                }
            }

            if groups.isEmpty {
                if viewModel.searchText.isEmpty {
                    HomeRecentEmptyState()
                } else {
                    HomeNoSearchResults {
                        viewModel.searchText = ""
                        isSearchFocused = true
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(groups, id: \.label) { group in
                        HomeGroupSection(
                            group: group,
                            onOpen: onOpenSession,
                            onDelete: viewModel.softDelete
                        )
                    }
                }
            }
        }
    }

    private var compactSearch: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.textOnBpDim)

            TextField(
                String(localized: "home.recent.search_placeholder"),
                text: $viewModel.searchText
            )
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundColor(.bpLine)
            .focused($isSearchFocused)
            .accessibilityIdentifier("home.recent.search")

            if viewModel.searchText.isEmpty == false {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.textOnBpDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "home.recent.search.clear"))
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(width: 260)
        .frame(minHeight: 36)
        .background(Color.bpBlueLight.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.bpLineGhost.opacity(0.6), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .focusRing(isSearchFocused, cornerRadius: Radius.sm)
    }
}

private struct HomeRecentEmptyState: View {
    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.textOnBpDim)
                .frame(width: 40, height: 40)
                .background(Color.bpBlueLight.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "home.recent.empty.title"))
                    .font(.bodyMedium)
                    .foregroundColor(.bpLine)

                Text(String(localized: "home.recent.empty.description"))
                    .font(.bodySM)
                    .foregroundColor(.textOnBpDim)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(Color.bpBlueLight.opacity(0.2))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.bpLineGhost.opacity(0.45), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }
}

private struct HomeNoSearchResults: View {
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "home.recent.no_match.title"))
                    .font(.bodyMedium)
                    .foregroundColor(.bpLine)
                Text(String(localized: "home.recent.no_match.description"))
                    .font(.bodySM)
                    .foregroundColor(.textOnBpDim)
            }

            Spacer()

            HomeActionButton(
                title: String(localized: "home.recent.search.clear"),
                icon: "xmark",
                style: .secondary,
                action: onClear
            )
        }
        .padding(Spacing.lg)
        .background(Color.bpBlueLight.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }
}

private struct HomeGroupSection: View {
    let group: SessionGroup
    let onOpen: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(group.label.uppercased())
                .font(.captionMedium)
                .tracking(0.8)
                .foregroundColor(.textOnBpDim)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(group.sessions) { session in
                    HomeSessionRow(
                        session: session,
                        onOpen: { onOpen(session.id) },
                        onDelete: { onDelete(session.id) }
                    )
                }
            }
        }
    }
}

private struct HomeSessionRow: View {
    let session: SessionListItem
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    Image(systemName: rowIcon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(rowIconColor)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.sm) {
                            Text(titleForDisplay)
                                .font(.bodyMedium)
                                .foregroundColor(.bpLine)
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
                                .foregroundColor(.textOnBpDim)
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
                        .foregroundColor(.textOnBpDim)
                        .padding(.top, Spacing.xs)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xsm)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($isFocused)
            .focusRing(isFocused, cornerRadius: Radius.sm)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(String(localized: "home.recent.row.open_hint"))
            .accessibilityIdentifier("home.session.\(session.id)")

            Menu {
                Button(role: .destructive, action: onDelete) {
                    Label(String(localized: "common.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textOnBpDim)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(
                String(format: String(localized: "home.recent.row.actions_format"), titleForDisplay)
            )
        }
        .padding(.trailing, Spacing.sm)
        .background(
            isHovering || isFocused
                ? Color.bpBlueLight.opacity(0.34)
                : Color.bpBlueLight.opacity(0.18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.bpLineGhost.opacity(0.45), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .onHover { isHovering = $0 }
        .animation(Motion.microInteraction, value: isHovering)
        .animation(Motion.microInteraction, value: isFocused)
    }

    private var metadata: some View {
        HStack(spacing: Spacing.sm) {
            Text(session.timeString)

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

        }
        .font(.captionMedium)
        .foregroundColor(.textOnBpDim)
    }

    private var titleForDisplay: String {
        let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "home.recent.row.untitled")
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
            : .textOnBpDim
    }

    private var statusLabel: (text: String, color: Color, icon: String)? {
        switch session.homeStatusState {
        case .recording:
            return (
                String(localized: "home.row.preview.recording"),
                .bpLine,
                "record.circle.fill"
            )
        case .transcribing:
            return (
                String(localized: "home.row.preview.pending"),
                .signalAmber,
                "hourglass"
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
                .bpLine,
                "checkmark.circle.fill"
            )
        case .imported:
            return (
                String(localized: "home.row.status.imported"),
                .bpLine,
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
            return (String(localized: "home.row.preview.no_speech"), .textOnBpDim)
        case .notTranscribed:
            return (String(localized: "home.row.preview.not_transcribed"), .textOnBpDim)
        case .none:
            return nil
        }
    }

    private var accessibilityLabel: String {
        var parts = [titleForDisplay, session.timeString]
        if session.durationString.isEmpty == false {
            parts.append(session.durationString)
        }
        if let statusLabel {
            parts.append(statusLabel.text)
        }
        return parts.joined(separator: ", ")
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
                    .foregroundColor(.bpLine)

                Text(String(localized: "home.create.description"))
                    .font(.bodySM)
                    .foregroundColor(.textOnBpDim)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "home.create.name_label"))
                    .font(.bodyMedium)
                    .foregroundColor(.bpLine)

                TextField(
                    String(localized: "home.create.name_placeholder"),
                    text: $title
                )
                .textFieldStyle(.plain)
                .font(.bodyLG)
                .foregroundColor(.bpLine)
                .padding(.horizontal, Spacing.md)
                .frame(minHeight: 44)
                .background(Color.bpBlueDeep.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(Color.bpLineGhost.opacity(0.7), lineWidth: Stroke.thin)
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
            .foregroundColor(.textOnBpDim)

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
        .background(Color.bpBlue)
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
            return .textOnBp
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return isHovering ? .brandAccentHover : .brandAccent
        case .secondary:
            return isHovering
                ? Color.bpBlueLight.opacity(0.75)
                : Color.bpBlueLight.opacity(0.45)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return .clear
        case .secondary:
            return Color.bpLineGhost.opacity(0.65)
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
