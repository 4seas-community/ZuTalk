// TrashPage.swift
// ZuTalk 回收站 — 列已软删的 session,支持恢复 / 永久删除。
//
// 数据源:core.listTrashedSessions() (返回 deleted_at IS NOT NULL 的 session)
// 操作:
//   - Restore:core.restoreSession → 回到 Home
//   - Purge:core.purgeSession → 清加密音频 + 删 session 记录(不可撤销)

import Combine
import SwiftUI

struct TrashPage: View {
    @StateObject private var viewModel = TrashViewModel()
    @State private var isConfirmingEmpty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                if viewModel.items.isEmpty {
                    EmptyState(
                        icon: "trash",
                        title: String(localized: "trash.empty.title"),
                        description: String(localized: "trash.empty.desc")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(viewModel.items) { item in
                            TrashRow(
                                session: item,
                                onRestore: { viewModel.restore(item.id) },
                                onPurge: { viewModel.purge(item.id) }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 1_080, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot)
        .onAppear { viewModel.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .zutalkSessionUpdated)) { _ in
            viewModel.reload()
        }
        .confirmationDialog(
            String(format: String(localized: "trash.empty_all.confirm_title_format"), Int64(viewModel.items.count)),
            isPresented: $isConfirmingEmpty,
            titleVisibility: .visible
        ) {
            Button(String(localized: "trash.empty_all.confirm_button"), role: .destructive) {
                viewModel.purgeAll()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "trash.purge.confirm_desc"))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "sidebar.trash"))
                    .font(.titleLG)
                    .foregroundColor(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(String(localized: "trash.subtitle"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.md)
            if viewModel.items.isEmpty == false {
                Button(role: .destructive) {
                    isConfirmingEmpty = true
                } label: {
                    Label(String(localized: "trash.empty_all"), systemImage: "trash.slash")
                }
                .accessibilityIdentifier("trash.empty_all")
            }
        }
    }
}

@MainActor
private final class TrashViewModel: ObservableObject {
    @Published var items: [SessionListItem] = []

    func reload() {
        guard let core = CoreClient.shared.core else { return }
        do {
            let infos = try core.listTrashedSessions()
            items = infos.map(LibraryViewModel.makeListItem)
        } catch {
            ToastCenter.shared.error(String(localized: "trash.load_failed"), detail: error.localizedDescription)
            items = []
        }
    }

    func restore(_ id: String) {
        guard let core = CoreClient.shared.core else { return }
        do {
            try core.restoreSession(sessionId: id)
            items.removeAll { $0.id == id }
            ToastCenter.shared.info(String(localized: "trash.toast.restored"))
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
        } catch {
            ToastCenter.shared.error(String(localized: "trash.restore_failed"), detail: error.localizedDescription)
        }
    }

    func purge(_ id: String) {
        guard let core = CoreClient.shared.core else { return }
        do {
            try core.purgeSession(sessionId: id)
            items.removeAll { $0.id == id }
            ToastCenter.shared.info(String(localized: "trash.toast.purged"))
        } catch {
            ToastCenter.shared.error(String(localized: "trash.purge_failed"), detail: error.localizedDescription)
        }
    }

    /// Empties the trash one recording at a time, so one that can't be
    /// deleted leaves the rest gone and says which remain.
    func purgeAll() {
        guard let core = CoreClient.shared.core else { return }
        var failed = 0
        for item in items {
            do {
                try core.purgeSession(sessionId: item.id)
            } catch {
                failed += 1
            }
        }
        reload()
        if failed == 0 {
            ToastCenter.shared.info(String(localized: "trash.toast.emptied"))
        } else {
            ToastCenter.shared.error(
                String(localized: "trash.purge_failed"),
                detail: String(format: String(localized: "trash.empty_all.partial_format"), Int64(failed))
            )
        }
    }
}

private struct TrashRow: View {
    let session: SessionListItem
    let onRestore: () -> Void
    let onPurge: () -> Void

    @State private var isHovering = false
    @State private var showPurgeConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .monospacedDigit()
                .frame(width: 132, alignment: .leading)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                RecordingRowText(
                    title: RecordingPresentation.title(session.title),
                    preview: session.preview,
                    placeholder: String(localized: "home.row.preview.not_transcribed")
                )
                if metadata.isEmpty == false {
                    Text(metadata)
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.sm)

            HStack(spacing: Spacing.sm) {
                Button(action: onRestore) {
                    Label(String(localized: "trash.action.restore"), systemImage: "arrow.uturn.backward")
                }
                .help(String(localized: "trash.action.restore_hint"))

                Button(role: .destructive) { showPurgeConfirm = true } label: {
                    Label(String(localized: "trash.action.purge"), systemImage: "trash.slash")
                }
                .confirmationDialog(
                    String(localized: "trash.purge.confirm_title"),
                    isPresented: $showPurgeConfirm
                ) {
                    Button(String(localized: "trash.purge.confirm_button"), role: .destructive) {
                        onPurge()
                    }
                    Button(String(localized: "common.cancel"), role: .cancel) { }
                } message: {
                    Text(String(localized: "trash.purge.confirm_desc"))
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xsm)
        .background(Color.bgElevated.opacity(isHovering ? 0.34 : 0.18))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.45), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .onHover { isHovering = $0 }
    }

    private var metadata: String {
        [
            RecordingPresentation.duration(ms: session.durationMs),
            RecordingPresentation.languageList(session.languageCodes).nilIfEmpty,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
struct TrashPage_Previews: PreviewProvider {
    static var previews: some View {
        TrashPage()
            .frame(width: 900, height: 600)
            .preferredColorScheme(.dark)
    }
}
#endif
