// SharedSessionView.swift
// 共享 session 的句块视图:收到(或共享中)的转录稿,权限内可订正。
//
// 数据源是 shared/ 目录里的 T2 块文档(sharedSessionBlocks),不是 SQLite
// ——收到的内容本机没有事实层,文档即真相。轮询刷新:远端更新经 doc-sync
// 合入后,下一拍就能看到;编辑走 sharedSession* 动词,提交即落盘并推送,
// 只读房间的观看者由调用方禁入口(推了也会被宿主拒收)。

import SwiftUI

struct SharedSessionView: View {
    let sessionId: String
    let editable: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var blocks: [FfiUtteranceBlock] = []
    @State private var pollTask: Task<Void, Never>?

    private var core: (any ZulangueCoreProtocol)? { CoreClient.shared.core }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "doc.text")
                    .foregroundColor(.textSecondary)
                Text(String(localized: "shared.editor.title"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                if !editable {
                    Label(
                        String(localized: "shared.editor.read_only"),
                        systemImage: "lock"
                    )
                    .font(.captionMedium)
                    .foregroundColor(.textTertiary)
                }
                if editable {
                    Button {
                        addAnnotation()
                    } label: {
                        Label(
                            String(localized: "shared.editor.add_annotation"),
                            systemImage: "plus.bubble"
                        )
                    }
                    .accessibilityIdentifier("shared.add_annotation")
                }
                Button(String(localized: "shared.editor.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.md)
            Divider().background(Color.borderGhost.opacity(0.25))

            if blocks.isEmpty {
                EmptyState(
                    icon: "tray",
                    title: String(localized: "shared.editor.empty_title"),
                    description: String(localized: "shared.editor.empty_body")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        ForEach(blocks, id: \.id) { block in
                            SharedBlockRow(
                                sessionId: sessionId,
                                block: block,
                                editable: editable
                            )
                        }
                    }
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Color.bgRoot)
        .task(id: sessionId) {
            refresh()
            // 远端更新经 doc-sync 到达后,下一拍可见。与字幕同一轮询哲学。
            pollTask?.cancel()
            pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(700))
                    refresh()
                }
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    private func refresh() {
        guard let core else { return }
        blocks = (try? core.sharedSessionBlocks(sessionId: sessionId)) ?? blocks
    }

    private func addAnnotation() {
        guard let core else { return }
        try? core.sharedSessionInsertAnnotation(
            sessionId: sessionId,
            index: UInt32(blocks.count),
            annotationId: UUID().uuidString,
            text: ""
        )
        refresh()
    }
}

/// 一个句块:原文 + 各语车道。draft 缓冲、失焦/回车提交,与车道编辑
/// 器同一手感;机器块与批注块共用此行,批注块没有车道。
private struct SharedBlockRow: View {
    let sessionId: String
    let block: FfiUtteranceBlock
    let editable: Bool

    @State private var textDraft: String
    @State private var laneDrafts: [String: String]

    private var core: (any ZulangueCoreProtocol)? { CoreClient.shared.core }
    private var isAnnotation: Bool { block.owner == "user" }

    init(sessionId: String, block: FfiUtteranceBlock, editable: Bool) {
        self.sessionId = sessionId
        self.block = block
        self.editable = editable
        self._textDraft = State(initialValue: block.text)
        self._laneDrafts = State(initialValue: block.lanes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Image(systemName: isAnnotation ? "bubble.left" : "waveform")
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
                    .accessibilityHidden(true)
                if editable {
                    TextField("", text: $textDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundColor(.textPrimary)
                        .onSubmit(commitText)
                } else {
                    Text(block.text)
                        .font(.body)
                        .foregroundColor(.textPrimary)
                        .textSelection(.enabled)
                }
            }
            ForEach(block.lanes.keys.sorted(), id: \.self) { lane in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(lane)
                        .font(.captionMedium)
                        .foregroundColor(.textTertiary)
                        .frame(width: 24, alignment: .trailing)
                    if editable {
                        TextField(
                            "",
                            text: Binding(
                                get: { laneDrafts[lane] ?? "" },
                                set: { laneDrafts[lane] = $0 }
                            ),
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                        .onSubmit { commitLane(lane) }
                    } else {
                        Text(block.lanes[lane] ?? "")
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        // 权威更新(远端合入)时,跟随最新值;编辑中的行由提交动作收口。
        .onChange(of: block.text) { _, newValue in textDraft = newValue }
        .onChange(of: block.lanes) { _, newValue in laneDrafts = newValue }
    }

    private func commitText() {
        guard let core, textDraft != block.text else { return }
        try? core.sharedSessionReplaceText(
            sessionId: sessionId,
            blockId: block.id,
            text: textDraft
        )
    }

    private func commitLane(_ lane: String) {
        guard let core,
              let draft = laneDrafts[lane],
              draft != block.lanes[lane]
        else { return }
        try? core.sharedSessionReplaceLane(
            sessionId: sessionId,
            blockId: block.id,
            lane: lane,
            text: draft
        )
    }
}
