// TrashPage.swift
// ZuTalk 回收站 — 列已软删的 session,支持恢复 / 永久删除。
//
// 数据源:core.listTrashedSessions() (返回 deleted_at IS NOT NULL 的 session)
// 操作:
//   - Restore:core.restoreSession → 回到 Home
//   - Purge:core.purgeSession → 清加密音频 + 删 session 记录(不可撤销)
//
// 页面上不写句子(docs/product/interface-layers.md「界面怎么写」):标题一个词,
// 每一行是「这是哪场录音」加两个动作,空的时候一句话。永久删除不能撤销 ——
// 这句告知在按下去那一刻的确认框里;原来标题下面那段话是标题的悬停提示。

import Combine
import SwiftUI

struct TrashPage: View {
    @StateObject private var viewModel: TrashViewModel
    @State private var isConfirmingEmpty = false

    /// - Parameter showing: Rows to show as they are, without reading the
    ///   library: a way to look at the page, not a second source of truth.
    init(showing items: [SessionListItem]? = nil) {
        _viewModel = StateObject(wrappedValue: TrashViewModel(fixedItems: items))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                if viewModel.items.isEmpty {
                    PlainEmptyLine(String(localized: "trash.empty.desc"))
                        .accessibilityIdentifier("trash.empty")
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
                    // What the page is and what its two actions do — the
                    // title's tooltip while the page had a title.
                    .help(String(localized: "trash.subtitle"))
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

    /// The window's header already says "Trash", so the page has no title
    /// of its own: it starts with the one thing that can be done to all of
    /// it, and with nothing when there is nothing to empty.
    @ViewBuilder
    private var header: some View {
        if viewModel.items.isEmpty == false {
            HStack(spacing: Spacing.sm) {
                Spacer(minLength: 0)
                // Quiet: emptying is the rare thing to do here, and it asks
                // before it does anything.
                ActionPill(
                    String(localized: "trash.action.empty"),
                    systemImage: "trash.slash",
                    style: .quiet,
                    help: String(localized: "trash.purge.confirm_desc"),
                    accessibilityLabel: String(localized: "trash.empty_all")
                ) {
                    isConfirmingEmpty = true
                }
                .accessibilityIdentifier("trash.empty_all")
            }
            .frame(minHeight: PillMetrics.height)
        }
    }
}

@MainActor
private final class TrashViewModel: ObservableObject {
    @Published var items: [SessionListItem] = []

    /// True when the rows were handed in rather than read: nothing is then
    /// read from, or changed in, the library.
    private let isFixed: Bool

    init(fixedItems: [SessionListItem]? = nil) {
        isFixed = fixedItems != nil
        items = fixedItems ?? []
    }

    func reload() {
        guard isFixed == false, let core = CoreClient.shared.core else { return }
        do {
            let infos = try core.listTrashedSessions()
            items = infos.map(LibraryViewModel.makeListItem)
        } catch {
            ToastCenter.shared.error(String(localized: "trash.load_failed"), detail: error.localizedDescription)
            items = []
        }
    }

    func restore(_ id: String) {
        guard isFixed == false, let core = CoreClient.shared.core else { return }
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
        guard isFixed == false, let core = CoreClient.shared.core else { return }
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
        guard isFixed == false, let core = CoreClient.shared.core else { return }
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

/// One deleted recording: when it was made, what it is, and the two things
/// that can be done with it.
private struct TrashRow: View {
    let session: SessionListItem
    let onRestore: () -> Void
    let onPurge: () -> Void

    @State private var isHovering = false
    @State private var showPurgeConfirm = false

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            // The day, and under it the time: two short lines of their own
            // rather than one long one that breaks wherever it runs out.
            VStack(alignment: .leading, spacing: 2) {
                Text(session.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .foregroundColor(.textSecondary)
                Text(session.createdAt.formatted(date: .omitted, time: .shortened))
                    .foregroundColor(.textTertiary)
            }
            .font(.bodySM)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: 112, alignment: .leading)
            .accessibilityElement(children: .combine)

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

            HStack(spacing: PillMetrics.spacing) {
                ActionPill(
                    String(localized: "trash.action.restore"),
                    systemImage: "arrow.uturn.backward",
                    help: String(localized: "trash.action.restore_hint"),
                    action: onRestore
                )
                .accessibilityIdentifier("trash.row.restore")

                // Asks first: the confirmation is where "cannot be undone"
                // is said.
                ActionPill(
                    String(localized: "common.delete"),
                    systemImage: "trash",
                    style: .quiet,
                    help: String(localized: "trash.purge.confirm_desc"),
                    accessibilityLabel: String(localized: "trash.action.purge")
                ) {
                    showPurgeConfirm = true
                }
                .accessibilityIdentifier("trash.row.purge")
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
