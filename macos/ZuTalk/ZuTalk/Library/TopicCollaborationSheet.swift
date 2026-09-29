// TopicCollaborationSheet.swift
// 和别人协作一个主题:邀请、看谁在、移出、退出。
//
// 协作走的是设备同步的同一套引擎(本地优先,不经服务器、不要账号):主题、
// 它的录音、转录稿、笔记、标记双方都能改,改动自动合并;音频永远只留在录音
// 的那台 Mac 上。邀请码是进这个主题的钥匙,十分钟内有效、只能用一次。

import Combine
import SwiftUI

struct TopicCollaborationSheet: View {
    let topicID: String
    let title: String

    @ObservedObject private var store = DeviceSyncStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var status: FfiTopicCollaboration?
    @State private var invite: DeviceSyncStore.PendingInvite?
    @State private var working = false
    @State private var problem: String?
    @State private var removing: FfiSyncDevice?
    @State private var confirmingLeave = false

    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(format: String(localized: "topic.collab.title_format"), title))
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "topic.collab.explain"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status?.removed == true {
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

            HStack {
                if status?.shared == true {
                    Button(role: .destructive) {
                        confirmingLeave = true
                    } label: {
                        Text(isOwner
                            ? String(localized: "topic.collab.stop")
                            : String(localized: "topic.collab.leave"))
                    }
                    .disabled(working)
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
            Button(
                isOwner ? String(localized: "topic.collab.stop") : String(localized: "topic.collab.leave"),
                role: .destructive,
                action: leave
            )
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(isOwner
                ? String(localized: "topic.collab.stop_confirm_message")
                : String(localized: "topic.collab.leave_confirm_message"))
        }
    }

    private var isOwner: Bool { status?.isOwner == true }

    /// 没在协作,或本机是发起人:能邀请。被邀请来的协作者不能再拉别人进来。
    private var canInvite: Bool {
        guard let status, status.shared else { return true }
        return status.isOwner
    }

    // MARK: - 成员

    private var members: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "topic.collab.members"))
                .font(.captionMedium)
                .foregroundColor(.textTertiary)
            ForEach(status?.members ?? [], id: \.deviceId) { member in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: member.isThisDevice ? "laptopcomputer" : "person")
                        .foregroundColor(.textTertiary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.isThisDevice
                            ? String(format: String(localized: "topic.collab.this_mac_format"), member.name)
                            : (member.name.isEmpty ? String(localized: "settings.devices.unnamed") : member.name))
                            .font(.bodySM)
                            .foregroundColor(.textPrimary)
                        if member.isThisDevice == false {
                            Text(DevicesSettingsSection.presence(member))
                                .font(.caption)
                                .foregroundColor(.textTertiary)
                        }
                    }
                    Spacer()
                    if isOwner, member.isThisDevice == false {
                        Button(String(localized: "settings.devices.remove")) { removing = member }
                            .disabled(working)
                    }
                }
            }
        }
    }

    // MARK: - 邀请

    @ViewBuilder
    private var inviteBlock: some View {
        if let invite, invite.expiresAt > Date() {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "topic.collab.code_hint"))
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                Text(invite.code)
                    .font(Font.mono10Medium)
                    .foregroundColor(.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("topic.collab.code")
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(String(
                            format: String(localized: "settings.devices.code_expires_format"),
                            DevicesSettingsSection.countdown(until: invite.expiresAt, now: context.date)
                        ))
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                    }
                    Spacer()
                    Button(String(localized: "settings.devices.copy_code")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.code, forType: .string)
                        ToastCenter.shared.success(String(localized: "sync.invite.copied"))
                    }
                }
            }
        } else {
            Button {
                createInvite()
            } label: {
                Label(String(localized: "topic.collab.invite"), systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(working)
            .accessibilityIdentifier("topic.collab.invite")
        }
    }

    // MARK: - 动作

    private func reload() {
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

/// 在主题列表里输入别人给的协作邀请码。
struct JoinTopicSheet: View {
    @ObservedObject private var store = DeviceSyncStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "topic.collab.join_title"))
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "topic.collab.join_explain"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            if let notebook = joined.notebookId {
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
