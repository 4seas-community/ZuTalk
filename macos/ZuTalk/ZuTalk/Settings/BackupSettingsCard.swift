// BackupSettingsCard.swift
// 设置 › 设备 › 备份:把这台的资料库每天加密备份到自己的另一台 Mac,只备文字;
// 需要时恢复到任何一台 Mac。
//
// 两个角色在同一张卡片里,因为用户站在哪台 Mac 前面都一样找得到:
//   - 这台被备份:生成备份码,到保管的那台上粘贴;之后每天自动做一份(没变就不做);
//   - 这台替别人保管:列出保管着谁的几份,可以生成恢复码,或删掉。
// 恢复码在要恢复的那台 Mac 上粘贴(和配对码同一个输入框)。恢复是合并:那台已经
// 有的不动,永久删除过的不会回来。

import SwiftUI

struct BackupSettingsCard: View {
    @ObservedObject private var store = DeviceSyncStore.shared
    @State private var removing: FfiSyncDevice?
    @State private var forgetting: FfiBackupHeld?
    @State private var restoring: RestoreRequest?

    private var targets: [FfiSyncDevice] { store.backup?.targets ?? [] }
    private var held: [FfiBackupHeld] { store.backup?.held ?? [] }

    var body: some View {
        SettingsCard(
            title: String(localized: "backup.title"),
            subtitle: String(localized: "backup.subtitle")
        ) {
            ForEach(Array(targets.enumerated()), id: \.element.deviceId) { index, target in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(
                    String(format: String(localized: "backup.target_format"), Self.name(target.name)),
                    description: DevicesSettingsSection.presence(target)
                ) {
                    Button(String(localized: "backup.stop")) { removing = target }
                }
            }
            if targets.isEmpty == false {
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "backup.last_title"),
                    description: lastBackup
                ) {
                    Button {
                        store.backupNow()
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            if store.backingUp { ProgressView().controlSize(.small) }
                            Text(String(localized: "backup.now"))
                        }
                    }
                    .disabled(store.backingUp)
                    .accessibilityIdentifier("settings.backup.now")
                }
                SettingsRowDivider()
            }
            inviteRow
            if held.isEmpty == false {
                SettingsRowDivider()
                SettingsFullRow {
                    Text(String(localized: "backup.held_title"))
                        .font(Font.sans12)
                        .foregroundColor(Color.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(held, id: \.spaceId) { held in
                    SettingsRowDivider()
                    heldRow(held)
                }
            }
        }
        .task {
            while Task.isCancelled == false {
                await store.refreshBackup()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .alert(
            removing.map { String(format: String(localized: "backup.stop_confirm_format"), Self.name($0.name)) } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { target in
            Button(String(localized: "backup.stop"), role: .destructive) {
                store.removeBackupTarget(target)
                removing = nil
            }
            Button(String(localized: "common.cancel"), role: .cancel) { removing = nil }
        } message: { _ in
            Text(String(localized: "backup.stop_confirm_message"))
        }
        .alert(
            forgetting.map { String(format: String(localized: "backup.forget_confirm_format"), Self.name($0.sourceName)) } ?? "",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { held in
            Button(String(localized: "backup.forget"), role: .destructive) {
                store.forgetHeld(held)
                forgetting = nil
            }
            Button(String(localized: "common.cancel"), role: .cancel) { forgetting = nil }
        } message: { _ in
            Text(String(localized: "backup.forget_confirm_message"))
        }
        .sheet(item: $restoring) { request in
            RestoreCodeSheet(held: request.held)
        }
    }

    // MARK: - 备份码

    @ViewBuilder
    private var inviteRow: some View {
        if let invite = store.backupInvite {
            SettingsFullRow {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(String(localized: "backup.code_hint"))
                        .font(Font.sans12)
                        .foregroundColor(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(invite.code)
                        .font(Font.mono10Medium)
                        .foregroundColor(Color.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.backup.code")
                    HStack(spacing: Spacing.sm) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(String(
                                format: String(localized: "settings.devices.code_expires_format"),
                                DevicesSettingsSection.countdown(until: invite.expiresAt, now: context.date)
                            ))
                            .font(Font.sans11)
                            .foregroundColor(Color.textTertiary)
                        }
                        Spacer()
                        Button(String(localized: "settings.devices.copy_code")) { store.copyBackupInvite() }
                        Button(String(localized: "settings.devices.cancel_code")) { store.cancelBackupInvite() }
                    }
                }
            }
        } else {
            SettingsRow(
                String(localized: targets.isEmpty ? "backup.add" : "backup.add_another"),
                description: String(localized: "backup.add_hint")
            ) {
                Button(String(localized: "backup.create_code")) { store.createBackupInvite() }
                    .disabled(store.busy)
                    .accessibilityIdentifier("settings.backup.create-code")
            }
        }
    }

    private var lastBackup: String {
        guard let made = store.backup?.lastMadeMs else {
            return String(localized: "backup.never")
        }
        let when = RelativeDateTimeFormatter().localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(made) / 1_000),
            relativeTo: Date()
        )
        let size = ByteCountFormatter.string(fromByteCount: Int64(store.backup?.lastBytes ?? 0), countStyle: .file)
        return String(format: String(localized: "backup.last_format"), when, size)
    }

    // MARK: - 替别人保管的

    private func heldRow(_ held: FfiBackupHeld) -> some View {
        SettingsRow(Self.name(held.sourceName), description: heldDetail(held)) {
            HStack(spacing: Spacing.sm) {
                Button(String(localized: "backup.restore")) {
                    restoring = RestoreRequest(held: held)
                }
                .disabled(held.copies.isEmpty)
                Button(String(localized: "backup.forget")) { forgetting = held }
            }
        }
    }

    private func heldDetail(_ held: FfiBackupHeld) -> String {
        guard let latest = held.copies.first else {
            return String(localized: "backup.held_waiting")
        }
        return String(
            format: String(localized: "backup.held_format"),
            Int64(held.copies.count),
            Self.date(latest.madeAtMs)
        )
    }

    static func name(_ name: String) -> String {
        name.isEmpty ? String(localized: "settings.devices.unnamed") : name
    }

    static func date(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1_000))
    }
}

private struct RestoreRequest: Identifiable {
    var id: String { held.spaceId }
    let held: FfiBackupHeld
}

/// 备份机上:挑一份,生成恢复码,拿到要恢复的 Mac 上粘贴。
private struct RestoreCodeSheet: View {
    let held: FfiBackupHeld

    @ObservedObject private var store = DeviceSyncStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Int64?
    @State private var code: String?
    @State private var expiresAt = Date()
    @State private var working = false
    @State private var problem: String?
    @State private var restoringHere = false

    /// 恢复码与备份机上的临时空间留多久,与核心里的一致。
    private static let lifetime: TimeInterval = 15 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(format: String(localized: "backup.restore_title_format"), BackupSettingsCard.name(held.sourceName)))
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "backup.restore_explain"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(String(localized: "backup.restore_which"), selection: $chosen) {
                ForEach(held.copies, id: \.madeAtMs) { copy in
                    Text(String(
                        format: String(localized: "backup.copy_format"),
                        BackupSettingsCard.date(copy.madeAtMs),
                        Int64(copy.recordings),
                        ByteCountFormatter.string(fromByteCount: Int64(copy.bytes), countStyle: .file)
                    ))
                    .tag(Int64?.some(copy.madeAtMs))
                }
            }
            .disabled(code != nil)

            if let code {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(code)
                        .font(Font.mono10Medium)
                        .foregroundColor(.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.backup.restore-code")
                    HStack {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(String(
                                format: String(localized: "settings.devices.code_expires_format"),
                                DevicesSettingsSection.countdown(until: expiresAt, now: context.date)
                            ))
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                        }
                        Spacer()
                        Button(String(localized: "settings.devices.copy_code")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            ToastCenter.shared.success(String(localized: "sync.invite.copied"))
                        }
                    }
                }
            } else {
                Button {
                    create()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if working { ProgressView().controlSize(.small) }
                        Text(String(localized: "backup.restore_create"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || held.copies.isEmpty)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 主力 Mac 坏了、在这台上接着用:不用恢复码,直接合进来。
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Button {
                    restoreHere()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if restoringHere { ProgressView().controlSize(.small) }
                        Text(String(localized: "backup.restore_here"))
                    }
                }
                .disabled(restoringHere || held.copies.isEmpty)
                .accessibilityIdentifier("settings.backup.restore-here")
                Text(String(localized: "backup.restore_here_hint"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(String(localized: "common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
        .onAppear { chosen = held.copies.first?.madeAtMs }
    }

    private func restoreHere() {
        restoringHere = true
        let spaceId = held.spaceId
        let madeAt = chosen
        Task {
            let done = await store.restoreHere(spaceId: spaceId, madeAtMs: madeAt)
            restoringHere = false
            if done { dismiss() }
        }
    }

    private func create() {
        working = true
        problem = nil
        let spaceId = held.spaceId
        let madeAt = chosen
        Task {
            let result = await store.restoreInvite(spaceId: spaceId, madeAtMs: madeAt)
            working = false
            switch result {
            case .success(let value):
                code = value
                expiresAt = Date().addingTimeInterval(Self.lifetime)
            case .failure(let error):
                problem = DeviceSyncStore.describe(error)
            }
        }
    }
}
