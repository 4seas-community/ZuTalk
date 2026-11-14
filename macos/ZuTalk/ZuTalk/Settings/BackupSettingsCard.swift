// BackupSettingsCard.swift
// 设置 › 高级 › 备份:把这台的资料库每天加密备份到自己的另一台 Mac,只备文字;
// 需要时恢复到任何一台 Mac。
//
// 两个角色在同一处,因为用户站在哪台 Mac 前面都一样找得到:
//   - 这台被备份:生成备份码,到保管的那台上粘贴;之后每天自动做一份(没变就不做);
//   - 这台替别人保管:列出保管着谁的几份,可以生成恢复码,或删掉。
// 备份码、恢复码都粘贴到「账号 › 设备」里配对的那个输入栏。恢复是合并:那台
// 已经有的不动,永久删除过的不会回来。
//
// 页面上没有句子:动作是胶囊,码是可以选中、可以复制的值,状态是一个图标加
// 几个词。备份是什么、只备文字不备音频、码拿到哪里去粘贴,在「备份」标题和
// 每一串码旁边的 ⓘ 里。停止备份、删除保管的备份,仍然先问一遍。
//
// 标题在卡片外面(「高级」一页的「备份」);出了错的那一句跟着卡片走。

import SwiftUI

/// 「备份」那一块画的是什么。纯数据,测试可以给任何一种。
struct BackupCardModel: Equatable {
    var status: FfiBackupStatus?
    var invite: DeviceSyncStore.PendingInvite?
    var busy = false
    var backingUp = false
    var problem: String?

    var targets: [FfiSyncDevice] { status?.targets ?? [] }
    var held: [FfiBackupHeld] { status?.held ?? [] }

    @MainActor
    static func live(_ store: DeviceSyncStore) -> BackupCardModel {
        BackupCardModel(
            status: store.backup,
            invite: store.backupInvite,
            busy: store.busy,
            backingUp: store.backingUp,
            problem: store.problem
        )
    }
}

struct BackupSettingsCard: View {
    @ObservedObject private var store = DeviceSyncStore.shared
    @Environment(\.settingsFixture) private var fixture
    @State private var removing: FfiSyncDevice?
    @State private var forgetting: FfiBackupHeld?
    @State private var restoring: RestoreRequest?

    private var model: BackupCardModel {
        fixture?.backup ?? .live(store)
    }

    /// 「备份」旁边 ⓘ 里的几句:备份的是什么(只备文字,音频不备份)、怎么加
    /// 一台保管它的 Mac。
    static var howBackupWorks: String {
        [
            String(localized: "backup.subtitle"),
            String(localized: "backup.add_hint_account"),
        ].joined(separator: "\n")
    }

    var body: some View {
        let model = model
        return VStack(alignment: .leading, spacing: Spacing.md) {
            outgoingCard(model)
            if model.held.isEmpty == false {
                heldCard(model)
            }
            if let problem = model.problem {
                SettingsProblem(problem)
                    .accessibilityIdentifier("settings.backup.problem")
            }
        }
        .task {
            guard fixture == nil else { return }
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

    // MARK: - 这台被备份

    private func outgoingCard(_ model: BackupCardModel) -> some View {
        SettingsCard {
            ForEach(model.targets, id: \.deviceId) { target in
                SettingsRow(
                    String(format: String(localized: "backup.target_format"), Self.name(target.name)),
                    description: DevicesSettingsSection.presence(target)
                ) {
                    DevicePresenceStatus(device: target)
                    ActionPill(
                        String(localized: "settings.action.stop"),
                        systemImage: "stop.circle",
                        help: String(localized: "backup.stop"),
                        accessibilityLabel: String(localized: "backup.stop")
                    ) {
                        removing = target
                    }
                }
                SettingsRowDivider()
            }
            if model.targets.isEmpty == false {
                SettingsRow(String(localized: "backup.last_title")) {
                    SettingsStatus(lastBackup(model), systemImage: "clock")
                    if model.backingUp {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: PillMetrics.height, height: PillMetrics.height)
                    }
                    ActionPill(
                        String(localized: "backup.now"),
                        systemImage: "arrow.up.circle"
                    ) {
                        store.backupNow()
                    }
                    .disabled(model.backingUp)
                    .accessibilityIdentifier("settings.backup.now")
                }
                SettingsRowDivider()
            }
            inviteRow(model)
        }
    }

    // MARK: - 备份码

    @ViewBuilder
    private func inviteRow(_ model: BackupCardModel) -> some View {
        if let invite = model.invite {
            // 码拿到哪里去粘贴:就在码旁边的 ⓘ 里。
            SettingsCodeRow(
                code: invite.code,
                expiresAt: invite.expiresAt,
                info: String(localized: "backup.code_hint_account"),
                codeIdentifier: "settings.backup.code",
                onCopy: { store.copyBackupInvite() },
                onCancel: { store.cancelBackupInvite() }
            )
        } else {
            SettingsRow(
                String(localized: "settings.backup.code"),
                description: String(localized: "backup.add_hint_account")
            ) {
                ActionPill(
                    String(localized: "settings.action.create"),
                    systemImage: "plus",
                    help: String(localized: "backup.add_hint_account"),
                    accessibilityLabel: String(localized: "backup.create_code")
                ) {
                    store.createBackupInvite()
                }
                .disabled(model.busy)
                .accessibilityIdentifier("settings.backup.create-code")
            }
        }
    }

    private func lastBackup(_ model: BackupCardModel) -> String {
        guard let made = model.status?.lastMadeMs else {
            return String(localized: "backup.never")
        }
        let when = RelativeDateTimeFormatter().localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(made) / 1_000),
            relativeTo: Date()
        )
        let size = ByteCountFormatter.string(fromByteCount: Int64(model.status?.lastBytes ?? 0), countStyle: .file)
        return String(format: String(localized: "backup.last_format"), when, size)
    }

    // MARK: - 替别人保管的

    private func heldCard(_ model: BackupCardModel) -> some View {
        SettingsCard(title: String(localized: "backup.held_title")) {
            ForEach(Array(model.held.enumerated()), id: \.element.spaceId) { index, held in
                if index > 0 { SettingsRowDivider() }
                heldRow(held)
            }
        }
    }

    private func heldRow(_ held: FfiBackupHeld) -> some View {
        SettingsRow(Self.name(held.sourceName), description: heldDetail(held)) {
            // How recent the newest copy is; how many there are and the
            // exact time are the row's tooltip.
            SettingsStatus(heldStatus(held), systemImage: "clock", help: heldDetail(held))
            ActionPill(
                String(localized: "backup.restore"),
                systemImage: "arrow.uturn.backward"
            ) {
                restoring = RestoreRequest(held: held)
            }
            .disabled(held.copies.isEmpty)
            ActionPill(
                nil,
                systemImage: "trash",
                help: String(localized: "backup.forget"),
                accessibilityLabel: String(localized: "backup.forget")
            ) {
                forgetting = held
            }
        }
    }

    private func heldStatus(_ held: FfiBackupHeld) -> String {
        guard let latest = held.copies.first else {
            return String(localized: "backup.held_waiting")
        }
        return RelativeDateTimeFormatter().localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(latest.madeAtMs) / 1_000),
            relativeTo: Date()
        )
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

/// 备份机上:挑一份,然后要么生成恢复码、拿到要恢复的 Mac 上粘贴,要么直接
/// 恢复到这台。恢复是怎么回事(合并、删掉的不回来、只有文字)在标题旁边的
/// ⓘ 里;「恢复到这台 Mac」会动这台的资料库,它旁边也有一个。
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
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                Text(String(format: String(localized: "backup.restore_title_format"), BackupSettingsCard.name(held.sourceName)))
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                InfoButton(String(localized: "backup.restore_explain_account"))
                    .accessibilityIdentifier("settings.backup.restore-info")
            }

            SettingsCard {
                SettingsRow(String(localized: "backup.restore_which")) {
                    copyPill
                }
                SettingsRowDivider()
                if let code {
                    SettingsCodeRow(
                        code: code,
                        expiresAt: expiresAt,
                        info: String(localized: "backup.restore_explain_account"),
                        codeIdentifier: "settings.backup.restore-code",
                        onCopy: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            ToastCenter.shared.success(String(localized: "sync.invite.copied"))
                        }
                    )
                } else {
                    SettingsFullRow {
                        HStack(spacing: PillMetrics.spacing) {
                            ActionPill(
                                String(localized: "backup.restore_create"),
                                systemImage: "plus",
                                help: String(localized: "backup.restore_explain_account"),
                                action: create
                            )
                            .disabled(working || held.copies.isEmpty)
                            .accessibilityIdentifier("settings.backup.restore-create")
                            if working { ProgressView().controlSize(.small) }
                        }
                    }
                }
                SettingsRowDivider()
                // 主力 Mac 坏了、在这台上接着用:不用恢复码,直接合进来。
                SettingsFullRow {
                    HStack(spacing: Spacing.xs) {
                        ActionPill(
                            String(localized: "backup.restore_here"),
                            systemImage: "arrow.down.to.line",
                            help: String(localized: "backup.restore_here_hint"),
                            action: restoreHere
                        )
                        .disabled(restoringHere || held.copies.isEmpty)
                        .accessibilityIdentifier("settings.backup.restore-here")
                        InfoButton(String(localized: "backup.restore_here_hint"))
                        if restoringHere { ProgressView().controlSize(.small) }
                    }
                }
            }

            if let problem {
                SettingsProblem(problem)
            }

            HStack {
                Spacer()
                Button(String(localized: "common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 480)
        .onAppear { chosen = held.copies.first?.madeAtMs }
    }

    /// 写着挑的是哪一份;点开是每一份,当前那一份打着勾。码生成以后就定了。
    private var copyPill: some View {
        let current = held.copies.first { $0.madeAtMs == chosen } ?? held.copies.first
        return MenuPill(
            current.map(Self.label) ?? String(localized: "backup.held_waiting"),
            titleIsName: true,
            systemImage: "clock.arrow.circlepath",
            accessibilityLabel: String(localized: "backup.restore_which")
        ) {
            held.copies.map { copy in
                PillMenuItem(Self.label(copy), isOn: copy.madeAtMs == chosen) {
                    chosen = copy.madeAtMs
                }
            }
        }
        .disabled(code != nil || held.copies.isEmpty)
    }

    private static func label(_ copy: FfiBackupCopy) -> String {
        String(
            format: String(localized: "backup.copy_format"),
            BackupSettingsCard.date(copy.madeAtMs),
            Int64(copy.recordings),
            ByteCountFormatter.string(fromByteCount: Int64(copy.bytes), countStyle: .file)
        )
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
