import AppKit
import SwiftUI

struct MainShellView: View {
    @ObservedObject private var softwareUpdate = SoftwareUpdateController.shared
    @ObservedObject private var store: MainNavigationStore
    @ObservedObject private var communityInvite = CommunityInviteSession.shared
    @State private var isSidebarHidden = false

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
        .background(Color.bpBlue.ignoresSafeArea())
        .toastOverlay()
        .onAppear { store.recordSnapshot() }
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
                    .background(Color.bpBlueDeep)
                    .overlay(
                        Rectangle()
                            .fill(Color.bpLineGhost.opacity(0.3))
                            .frame(width: 0.5),
                        alignment: .trailing
                    )
            }

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.bpBlue)
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
                sidebarItem(
                    icon: "house.fill",
                    label: String(localized: "sidebar.home"),
                    active: activeTab == .home,
                    accId: AccessibilityID.mainTabHome
                ) {
                    store.select(tab: .home)
                }

                sidebarItem(
                    icon: "books.vertical.fill",
                    label: String(localized: "sidebar.knowledge"),
                    active: activeTab == .knowledge,
                    accId: AccessibilityID.mainTabKnowledge
                ) {
                    store.select(tab: .knowledge)
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
            }
            .padding(.horizontal, Spacing.sm)

            Spacer()

            sidebarFooter
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)
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
            Image("ZulangueMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundColor(.brandAccent)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            Text("Zulangue")
                .font(.brandCaption)
                .tracking(1.4)
                .foregroundColor(.bpLine)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Zulangue")
    }

    private var sidebarCollapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isSidebarHidden = true
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.textOnBpDim)
                .frame(width: 28, height: 28)
                .background(Color.bpBlueChip)
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
                    .foregroundColor(active ? .brandAccent : .textOnBpDim)
                    .frame(width: 18)
                Text(label)
                    .font(.body)
                    .foregroundColor(active ? .bpLine : .textOnBpDim)
                Spacer()
            }
            .padding(.horizontal, Spacing.sm + 2)
            .frame(minHeight: 44)
            .background(active ? Color.bpBlueLight.opacity(0.5) : Color.clear)
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
                .fill(Color.bpLineGhost.opacity(0.4))
                .frame(height: 0.5)

            if softwareUpdate.isUpdateReadyToInstall {
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
            }

            if communityInvite.isEnabled, communityInvite.isActive {
                Label(
                    communityTimeLabel,
                    systemImage: "gift.fill"
                )
                .font(.bodySM)
                .foregroundColor(.textOnBpDim)
                .accessibilityIdentifier("sidebar.community-invite.remaining")
                .task { await communityInvite.refreshQuota() }
            }

            HStack(spacing: Spacing.sm) {
                Label(
                    String(localized: "sidebar.local_first"),
                    systemImage: "lock.shield.fill"
                )
                .font(.bodySM)
                .foregroundColor(.textOnBpDim)

                Spacer()

                Button(action: { store.openSettings() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(activeTab == .config ? .brandAccent : .textOnBpDim)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .help(String(localized: "sidebar.tab.settings"))
                .accessibilityLabel(String(localized: "sidebar.tab.settings"))
                .accessibilityAddTraits(activeTab == .config ? .isSelected : [])
                .accessibilityIdentifier(AccessibilityID.mainTabConfig)
            }
        }
    }

    private var communityTimeLabel: String {
        guard let seconds = communityInvite.remainingSeconds else {
            return String(localized: "community_invite.active")
        }
        let hours = max(0, seconds / 3_600)
        return String(
            format: String(localized: "community_invite.remaining_hours_format"),
            Int64(hours)
        )
    }

    private var contentArea: some View {
        VStack(spacing: 0) {
            contentHeader
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .frame(height: 56)
                .overlay(
                    Rectangle()
                        .fill(Color.bpLineGhost.opacity(0.3))
                        .frame(height: 0.5),
                    alignment: .bottom
                )

            ZStack {
                Color.bpBlue

                Group {
                    switch activeTab {
                    case .home:
                        HomeView()
                    case .knowledge:
                        KnowledgeLibraryPage()
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
        HStack(spacing: Spacing.md) {
            if isSidebarHidden {
                sidebarRevealButton
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: tabIcon(for: activeTab))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textOnBpDim)
                Text(tabTitle(for: activeTab))
                    .font(.bodyMedium)
                    .foregroundColor(.bpLine)
            }

            Spacer()

        }
    }

    private var sidebarRevealButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isSidebarHidden = false
            }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.textOnBpDim)
                .frame(width: 28, height: 28)
                .background(Color.bpBlueChip)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .help(String(localized: "sidebar.expand"))
        .accessibilityLabel(String(localized: "sidebar.expand"))
        .accessibilityIdentifier("sidebar.expand")
    }

    private func tabIcon(for tab: MainTab) -> String {
        switch tab {
        case .home:
            return "house.fill"
        case .knowledge:
            return "books.vertical.fill"
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
        case .home:
            return String(localized: "sidebar.home")
        case .knowledge:
            return String(localized: "sidebar.knowledge")
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
