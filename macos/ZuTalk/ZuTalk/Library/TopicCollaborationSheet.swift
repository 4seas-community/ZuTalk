// TopicCollaborationSheet.swift
// 和别人协作一个主题:邀请、看谁在、移出、退出。
//
// 协作走的是设备同步的同一套引擎(本地优先,不经服务器、不要账号):主题、
// 它的录音、转录稿、笔记、标记双方都能改,改动自动合并;音频永远只留在录音
// 的那台 Mac 上。邀请码是进这个主题的钥匙,十分钟内有效、只能用一次。
//
// 面板上不写段落(docs/product/interface-layers.md「界面怎么写」)。上面那段话
// 是告知 —— 对方能看到什么、音频不会过去 —— 所以没有删,在标题旁边的 ⓘ 里;
// 邀请码怎么用,在邀请码旁边的 ⓘ 里;移出和停止各自的后果,在按下去那一刻的
// 确认框里。

import Combine
import SwiftUI

struct TopicCollaborationSheet: View {
    /// A state to show as it is, without asking the sync engine: a way to
    /// look at the sheet, not a second source of truth.
    struct Showing {
        var status: FfiTopicCollaboration?
        var invite: DeviceSyncStore.PendingInvite?
        var problem: String?
    }

    let topicID: String
    let title: String
    private let isFixed: Bool

    @ObservedObject private var store = DeviceSyncStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var status: FfiTopicCollaboration?
    @State private var invite: DeviceSyncStore.PendingInvite?
    @State private var working = false
    @State private var problem: String?
    @State private var removing: FfiSyncDevice?
    @State private var confirmingLeave = false

    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    init(topicID: String, title: String, showing: Showing? = nil) {
        self.topicID = topicID
        self.title = title
        isFixed = showing != nil
        _status = State(initialValue: showing?.status)
        _invite = State(initialValue: showing?.invite)
        _problem = State(initialValue: showing?.problem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // The topic's name, and beside it what collaborating shares and
            // what it never does.
            HStack(spacing: 2) {
                Text(heading)
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                InfoButton(String(localized: "topic.collab.explain"), accessibilityLabel: heading)
                .accessibilityIdentifier("topic.collab.info")
                Spacer(minLength: 0)
            }

            if status?.removed == true {
                // A status: said once, in full.
                Label(String(localized: "topic.collab.removed"), systemImage: "person.crop.circle.badge.xmark")
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status?.shared == true {
                members
            }

            if canInvite {
                inviteBlock
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.md) {
                if status?.shared == true {
                    // Quiet, and it asks first: the confirmation says what
                    // stopping leaves behind.
                    ActionPill(
                        String(localized: isOwner ? "topic.collab.action.stop" : "topic.collab.action.leave"),
                        systemImage: isOwner ? "stop.circle" : "rectangle.portrait.and.arrow.right",
                        style: .quiet,
                        help: leaveExplanation,
                        accessibilityLabel: leaveLabel
                    ) {
                        confirmingLeave = true
                    }
                    .disabled(working)
                    .accessibilityIdentifier("topic.collab.leave")
                }
                Spacer()
                Button(String(localized: "common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
        .onAppear(perform: reload)
        .onReceive(tick) { _ in reload() }
        .alert(
            removing.map { String(format: String(localized: "topic.collab.remove_confirm_format"), $0.name) } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { device in
            Button(String(localized: "settings.devices.remove"), role: .destructive) { remove(device) }
            Button(String(localized: "common.cancel"), role: .cancel) { removing = nil }
        } message: { _ in
            Text(String(localized: "topic.collab.remove_confirm_message"))
        }
        .alert(
            isOwner
                ? String(localized: "topic.collab.stop_confirm_title")
                : String(localized: "topic.collab.leave_confirm_title"),
            isPresented: $confirmingLeave
        ) {
            Button(leaveLabel, role: .destructive, action: leave)
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(leaveExplanation)
        }
    }

    private var heading: String {
        String(format: String(localized: "topic.collab.title_format"), title)
    }

    private var isOwner: Bool { status?.isOwner == true }

    /// 没在协作,或本机是发起人:能邀请。被邀请来的协作者不能再拉别人进来。
    private var canInvite: Bool {
        guard let status, status.shared else { return true }
        return status.isOwner
    }

    /// What the quiet pill at the bottom does, in full: the pill itself says
    /// it in one word.
    private var leaveLabel: String {
        String(localized: isOwner ? "topic.collab.stop" : "topic.collab.leave")
    }

    private var leaveExplanation: String {
        String(localized: isOwner
            ? "topic.collab.stop_confirm_message"
            : "topic.collab.leave_confirm_message")
    }

    // MARK: - 成员

    private var members: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            PlainSectionHeader(String(localized: "topic.collab.members"))
            ForEach(status?.members ?? [], id: \.deviceId) { member in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: member.isThisDevice ? "laptopcomputer" : "person")
                        .foregroundColor(.textTertiary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(member.isThisDevice
                        ? String(format: String(localized: "topic.collab.this_mac_format"), member.name)
                        : (member.name.isEmpty ? String(localized: "settings.devices.unnamed") : member.name))
                        .font(.body)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.sm)
                    if member.isThisDevice == false {
                        PlainStatus(
                            DevicesSettingsSection.presence(member),
                            systemImage: nil,
                            tint: member.connected ? .signalGreen : .textTertiary
                        )
                    }
                    if isOwner, member.isThisDevice == false {
                        ActionPill(
                            String(localized: "settings.devices.remove"),
                            systemImage: "person.badge.minus",
                            style: .quiet,
                            help: String(localized: "topic.collab.remove_confirm_message")
                        ) {
                            removing = member
                        }
                        .disabled(working)
                    }
                }
                .frame(minHeight: PillMetrics.height)
            }
        }
    }

    // MARK: - 邀请

    @ViewBuilder
    private var inviteBlock: some View {
        if let invite, invite.expiresAt > Date() {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                PlainSectionHeader(
                    String(localized: "topic.collab.join_placeholder"),
                    help: String(localized: "topic.collab.code_hint")
                )
                // The code is a value: shown whole, selectable, with Copy
                // beside it.
                Text(invite.code)
                    .font(Font.mono10Medium)
                    .foregroundColor(.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.sm)
                    .background(Color.bgSunken.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    .accessibilityIdentifier("topic.collab.code")
                HStack(spacing: Spacing.sm) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        PlainStatus(
                            String(
                                format: String(localized: "settings.devices.code_expires_format"),
                                DevicesSettingsSection.countdown(until: invite.expiresAt, now: context.date)
                            ),
                            systemImage: "clock"
                        )
                    }
                    Spacer(minLength: Spacing.sm)
                    // Where the other person pastes it: needed to finish
                    // the job, so one click away rather than a tooltip only.
                    InfoButton(
                        String(localized: "topic.collab.code_hint"),
                        accessibilityLabel: String(localized: "topic.collab.join_placeholder")
                    )
                    ActionPill(
                        String(localized: "topic.collab.action.copy"),
                        systemImage: "doc.on.doc"
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.code, forType: .string)
                        ToastCenter.shared.success(String(localized: "sync.invite.copied"))
                    }
                    .accessibilityIdentifier("topic.collab.copy")
                }
            }
        } else {
            ActionPill(
                String(localized: "topic.collab.action.invite"),
                systemImage: "person.badge.plus",
                help: String(localized: "topic.collab.code_hint"),
                accessibilityLabel: String(localized: "topic.collab.invite")
            ) {
                createInvite()
            }
            .disabled(working)
            .accessibilityIdentifier("topic.collab.invite")
        }
    }

    // MARK: - 动作

    private func reload() {
        guard isFixed == false else { return }
        status = store.topicStatus(notebookId: topicID)
    }

    private func createInvite() {
        working = true
        problem = nil
        Task {
            let result = await store.topicInvite(notebookId: topicID)
            working = false
            switch result {
            case .success(let code):
                invite = DeviceSyncStore.PendingInvite(
                    code: code,
                    expiresAt: Date().addingTimeInterval(DeviceSyncStore.inviteLifetime)
                )
                reload()
            case .failure(let error):
                problem = DeviceSyncStore.describe(error)
            }
        }
    }

    private func remove(_ member: FfiSyncDevice) {
        removing = nil
        working = true
        Task {
            if let error = await store.removeTopicMember(notebookId: topicID, deviceId: member.deviceId) {
                problem = DeviceSyncStore.describe(error)
            }
            working = false
            reload()
        }
    }

    private func leave() {
        working = true
        Task {
            if let error = await store.leaveTopic(notebookId: topicID) {
                problem = DeviceSyncStore.describe(error)
                working = false
                return
            }
            working = false
            invite = nil
            reload()
        }
    }
}

/// 在主题列表里输入别人给的协作邀请码。标题旁边的 ⓘ 里是告知:什么会同步过来,
/// 音频留在对方那里。
struct JoinTopicSheet: View {
    @ObservedObject private var store = DeviceSyncStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: 2) {
                Text(String(localized: "topic.collab.join_title"))
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                InfoButton(
                    String(localized: "topic.collab.join_explain"),
                    accessibilityLabel: String(localized: "topic.collab.join_title")
                )
                .accessibilityIdentifier("topic.collab.join-info")
                Spacer(minLength: 0)
            }
            TextField(String(localized: "topic.collab.join_placeholder"), text: $code)
                .textFieldStyle(.roundedBorder)
                .onSubmit(join)
                .accessibilityIdentifier("topic.collab.join-code")
            if store.busy {
                ProgressView().controlSize(.small)
            }
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "common.cancel")) { dismiss() }
                Button(String(localized: "settings.devices.join"), action: join)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
    }

    private func join() {
        let pasted = code
        Task {
            guard let joined = await store.join(code: pasted) else { return }
            dismiss()
            if joined.purpose == .backup {
                ToastCenter.shared.success(String(
                    format: String(localized: joined.restoring ? "backup.restoring_format" : "backup.holding_format"),
                    joined.label
                ))
            } else if let notebook = joined.notebookId {
                ToastCenter.shared.success(String(
                    format: String(localized: "topic.collab.joined_format"), joined.label
                ))
                MainNavigationStore.shared.openTopicWorkspace(notebookID: notebook)
            } else {
                ToastCenter.shared.success(String(
                    format: String(localized: "settings.devices.joined_format"), joined.inviterName
                ))
            }
        }
    }
}
