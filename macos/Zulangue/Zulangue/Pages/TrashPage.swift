// TrashPage.swift
// Zulangue 回收站 — 列已软删的 session,支持恢复 / 永久删除。
//
// 数据源:core.listTrashedSessions() (返回 deleted_at IS NOT NULL 的 session)
// 操作:
//   - Restore:core.restoreSession → 回到 Home
//   - Purge:core.purgeSession → 清加密音频 + 删 session 记录(不可撤销)

import Combine
import SwiftUI

struct TrashPage: View {
    @StateObject private var viewModel = TrashViewModel()

    var body: some View {
        Group {
            if viewModel.items.isEmpty {
                EmptyState(
                    icon: "trash",
                    title: String(localized: "trash.empty.title"),
                    description: String(localized: "trash.empty.desc")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(viewModel.items) { item in
                            TrashRow(
                                session: item,
                                onRestore: { viewModel.restore(item.id) },
                                onPurge: { viewModel.purge(item.id) }
                            )
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot)
        .onAppear { viewModel.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .zulangueSessionUpdated)) { _ in
            viewModel.reload()
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
            ToastCenter.shared.error("Load trash failed", detail: "\(error)")
            items = []
        }
    }

    func restore(_ id: String) {
        guard let core = CoreClient.shared.core else { return }
        do {
            try core.restoreSession(sessionId: id)
            items.removeAll { $0.id == id }
            ToastCenter.shared.info(String(localized: "trash.toast.restored"))
            NotificationCenter.default.post(name: .zulangueSessionUpdated, object: nil)
        } catch {
            ToastCenter.shared.error("Restore failed", detail: "\(error)")
        }
    }

    func purge(_ id: String) {
        guard let core = CoreClient.shared.core else { return }
        do {
            try core.purgeSession(sessionId: id)
            items.removeAll { $0.id == id }
            ToastCenter.shared.info(String(localized: "trash.toast.purged"))
        } catch {
            ToastCenter.shared.error("Purge failed", detail: "\(error)")
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
            VStack(alignment: .leading, spacing: 4) {
                Text(titleForDisplay)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary.opacity(0.85))
                    .lineLimit(1)

                if !session.preview.isEmpty {
                    Text(session.preview)
                        .font(.caption)
                        .foregroundColor(.textSecondary.opacity(0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Text(session.timeString)
                        .font(.captionMedium)
                        .foregroundColor(.textTertiary)
                    if session.durationString != "00:00" {
                        Text("·")
                            .font(.captionMedium)
                            .foregroundColor(.textTertiary)
                        Text(session.durationString)
                            .font(.captionMedium)
                            .foregroundColor(.textTertiary)
                    }
                }
            }

            Spacer()

            HStack(spacing: Spacing.sm) {
                Button(action: onRestore) {
                    Label(
                        String(localized: "trash.action.restore"),
                        systemImage: "arrow.uturn.backward"
                    )
                    .labelStyle(.iconOnly)
                    .foregroundColor(.brandAccent)
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(Color.borderGhost.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help(String(localized: "trash.action.restore"))

                Button { showPurgeConfirm = true } label: {
                    Label(
                        String(localized: "trash.action.purge"),
                        systemImage: "trash.slash"
                    )
                    .labelStyle(.iconOnly)
                    .foregroundColor(.signalRed)
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(Color.signalRed.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help(String(localized: "trash.action.purge"))
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
        .padding(.vertical, Spacing.sm + 2)
        .background(isHovering ? Color.bgElevated.opacity(0.25) : Color.clear)
        .overlay(
            Rectangle()
                .fill(Color.borderGhost.opacity(0.12))
                .frame(height: 0.5),
            alignment: .bottom
        )
        .onHover { isHovering = $0 }
    }

    private var titleForDisplay: String {
        let trimmed = session.title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return "Untitled · \(session.id.prefix(6))"
    }
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
