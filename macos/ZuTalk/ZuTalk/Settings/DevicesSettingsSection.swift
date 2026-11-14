// DevicesSettingsSection.swift
// 「设置 › 账号」里的「设备」:自己的几台 Mac 之间同步。一张卡,从上到下:
//   同步(开 / 关)· 附近(开 / 关)· 这台 Mac 的名字 · 已经配上的每一台 ·
//   配对(生成配对码,或者把另一台的码贴进来)。
//
// 配对是两台之间的事:一台生成配对码,另一台输入。两个动作在同一张卡里,
// 因为用户站在哪台 Mac 前面都一样找得到。
//
// 卡片上没有句子。「它怎么工作」那几条(直连还是经中继、音频不离开录音的那台、
// 配对码是进资料库的钥匙)是必须让人读得到的告知,在「设备」标题旁边的 ⓘ 里;
// 每一行自己的那句说明在悬停提示里。移除一台、让这台离开,仍然先问一遍。
//
// 备份不在这里,在「高级 › 备份」;但备份码、恢复码仍然粘贴到这里配对的那
// 一栏,所以备份那边的说明指回这里。

import SwiftUI

/// 「设备」那张卡画的是什么。纯数据:卡片只看它,测试可以给它任何一种。
struct DevicesCardModel: Equatable {
    var enabled = false
    var deviceName = ""
    var removedFromGroup = false
    var others: [FfiSyncDevice] = []
    var invite: DeviceSyncStore.PendingInvite?
    var busy = false
    var problem: String?
    var nearbyReceiving = false
    var nearby: FfiNearbyStatus?

    @MainActor
    static func live(store: DeviceSyncStore, nearby: NearbyStore) -> DevicesCardModel {
        DevicesCardModel(
            enabled: store.enabled,
            deviceName: store.deviceName,
            removedFromGroup: store.removedFromGroup,
            others: store.otherDevices,
            invite: store.invite,
            busy: store.busy,
            problem: store.problem,
            nearbyReceiving: nearby.receiving,
            nearby: nearby.status
        )
    }

    /// 这台 Mac 和别的 Mac 配着,而且没被移出去:这时候才谈得上「离开」。
    var canLeave: Bool {
        enabled && others.isEmpty == false && removedFromGroup == false
    }

    /// 附近看得见谁。没人的时候不占一行(那一句在「附近」的提示里);局域网
    /// 发现关着(只在开发构建里会这样)时直说。
    var nearbyStatusLine: String? {
        guard enabled, let nearby, nearby.running else { return nil }
        guard nearby.discovery else { return String(localized: "nearby.settings.discovery_off") }
        let names = nearby.peers.map {
            $0.name.isEmpty ? String(localized: "settings.devices.unnamed") : $0.name
        }
        guard names.isEmpty == false else { return nil }
        return String(
            format: String(localized: "nearby.settings.seen_format"),
            ListFormatter.localizedString(byJoining: names)
        )
    }
}

struct DevicesSettingsSection: View {
    @ObservedObject private var store = DeviceSyncStore.shared
    @ObservedObject private var nearby = NearbyStore.shared
    @Environment(\.settingsFixture) private var fixture
    @State private var nameDraft = ""
    @State private var joinCode = ""
    @State private var joinedWith: String?
    @State private var removing: FfiSyncDevice?
    @State private var confirmingLeave = false

    private var model: DevicesCardModel {
        fixture?.devices ?? .live(store: store, nearby: nearby)
    }

    var body: some View {
        let model = model
        return SettingsGroup(
            title: String(localized: "settings.group.devices"),
            subtitle: String(localized: "settings.account.devices_subtitle"),
            info: Self.howItWorks
        ) {
            SettingsCard {
                syncRow(model)
                SettingsRowDivider()
                nearbyRow(model)
                if let seen = model.nearbyStatusLine {
                    SettingsRowDivider()
                    SettingsFullRow {
                        SettingsStatus(seen, systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                SettingsRowDivider()
                thisMacRow(model)

                if model.enabled, model.removedFromGroup {
                    SettingsRowDivider()
                    removedRow(model)
                }

                if model.enabled {
                    Group {
                        ForEach(model.others, id: \.deviceId) { device in
                            SettingsRowDivider()
                            deviceRow(device)
                        }
                    }
                    .accessibilityIdentifier("settings.devices.list")

                    SettingsRowDivider()
                    inviteRow(model)
                    SettingsRowDivider()
                    joinRow(model)
                }
            }

            if let problem = model.problem {
                SettingsProblem(problem)
                    .accessibilityIdentifier("settings.devices.problem")
            }
        }
        .onAppear {
            nameDraft = model.deviceName
            guard fixture == nil else { return }
            store.refresh()
        }
        .alert(
            removing.map { String(format: String(localized: "settings.devices.remove_confirm_title"), $0.name) } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { device in
            Button(String(localized: "settings.devices.remove"), role: .destructive) {
                store.remove(device)
                removing = nil
            }
            Button(String(localized: "common.cancel"), role: .cancel) { removing = nil }
        } message: { _ in
            Text(String(localized: "settings.devices.remove_confirm_message"))
        }
        .alert(
            String(localized: "settings.devices.leave_confirm_title"),
            isPresented: $confirmingLeave
        ) {
            Button(String(localized: "settings.devices.leave"), role: .destructive) {
                store.leaveGroup()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.devices.leave_confirm_message"))
        }
    }

    /// 「设备」旁边 ⓘ 里的几句:同步的是什么、怎么传、音频在哪、配对码要当心。
    static var howItWorks: String {
        [
            "settings.account.devices_subtitle",
            "settings.devices.how_direct",
            "settings.devices.how_audio",
            "settings.devices.how_recording",
            "settings.devices.how_code",
        ]
        .map { String(localized: String.LocalizationValue($0)) }
        .joined(separator: "\n")
    }

    // MARK: - 开关与名字

    private func syncRow(_ model: DevicesCardModel) -> some View {
        SettingsRow(
            String(localized: "settings.devices.sync_title"),
            description: String(localized: "settings.devices.enable_hint")
        ) {
            SettingsSwitch(
                isOn: model.enabled,
                label: String(localized: "settings.devices.enable"),
                help: String(localized: "settings.devices.enable_hint")
            ) {
                store.setEnabled($0)
            }
            .accessibilityIdentifier("settings.devices.enable")
        }
    }

    private func nearbyRow(_ model: DevicesCardModel) -> some View {
        let explanation = [
            String(localized: "nearby.settings.receiving_hint"),
            String(localized: "nearby.settings.subtitle"),
            // 没人的时候那一句不占一行,在这里。
            model.enabled && model.nearby?.running == true && model.nearbyStatusLine == nil
                ? String(localized: "nearby.settings.nobody")
                : nil,
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        // 打开以后,同一网络里的 ZuTalk 看得到这台的名字:这是告知,所以名字
        // 旁边有 ⓘ,不只在悬停提示里。ⓘ 紧挨着那个词(和「设备 ⓘ」一样):
        // `SettingsRow` 给名字留了最小宽度,两个字的名字后面会空出一截,所以
        // 这一行自己排。
        let title = String(localized: "nearby.settings.title")
        return SettingsFullRow {
            HStack(alignment: .center, spacing: PillMetrics.spacing) {
                HStack(spacing: 2) {
                    Text(title)
                        .font(PillMetrics.font)
                        .foregroundColor(Color.textPrimary)
                        .lineLimit(1)
                        .accessibilityHint(Text(explanation))
                    InfoButton(
                        [
                            String(localized: "nearby.settings.receiving_hint"),
                            String(localized: "nearby.settings.subtitle"),
                        ].joined(separator: "\n"),
                        accessibilityLabel: title
                    )
                }
                Spacer(minLength: Spacing.sm)
                SettingsSwitch(
                    isOn: model.nearbyReceiving,
                    label: String(localized: "nearby.settings.receiving"),
                    help: explanation
                ) {
                    nearby.setReceiving($0)
                }
                .accessibilityIdentifier("settings.devices.nearby-receiving")
            }
        }
        .help(explanation)
    }

    private func thisMacRow(_ model: DevicesCardModel) -> some View {
        SettingsRow(
            String(localized: "settings.devices.this_mac_label"),
            description: String(localized: "settings.devices.this_mac_hint")
        ) {
            SettingsField("", text: $nameDraft, onSubmit: { store.rename(nameDraft) })
                .frame(minWidth: 120, maxWidth: 180)
                .accessibilityLabel(String(localized: "settings.devices.this_mac"))
                .accessibilityIdentifier("settings.devices.name")

            if model.canLeave {
                ActionPill(
                    String(localized: "settings.devices.leave"),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    help: String(localized: "settings.devices.leave_hint")
                ) {
                    confirmingLeave = true
                }
                .disabled(model.busy)
                .accessibilityIdentifier("settings.devices.leave")
            }
        }
    }

    /// 这台被别的 Mac 移了出去:出了事的那一句,和唯一能做的事。
    private func removedRow(_ model: DevicesCardModel) -> some View {
        SettingsRow(
            String(localized: "settings.devices.removed_title"),
            info: String(localized: "settings.devices.removed_message")
        ) {
            ActionPill(
                String(localized: "settings.devices.start_over"),
                systemImage: "arrow.counterclockwise",
                tone: .warning
            ) {
                store.leaveGroup()
            }
            .disabled(model.busy)
            .accessibilityIdentifier("settings.devices.start-over")
        }
    }

    // MARK: - 设备行

    private func deviceRow(_ device: FfiSyncDevice) -> some View {
        SettingsRow(
            device.name.isEmpty ? String(localized: "settings.devices.unnamed") : device.name,
            description: Self.presence(device)
        ) {
            DevicePresenceStatus(device: device)
            ActionPill(
                String(localized: "settings.devices.remove"),
                systemImage: "minus.circle"
            ) {
                removing = device
            }
        }
    }

    /// 整句的在线状态:「在线 · 直连」「不在线 · 上次同步 3 小时前」。行上只写
    /// 一个词(`DevicePresenceStatus`),这一句在提示里。
    static func presence(_ device: FfiSyncDevice) -> String {
        if device.connected {
            return device.viaRelay
                ? String(localized: "settings.devices.online_relay")
                : String(localized: "settings.devices.online_direct")
        }
        guard let last = device.lastSyncedUnixMs else {
            return String(localized: "settings.devices.offline")
        }
        let when = RelativeDateTimeFormatter().localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(last) / 1_000),
            relativeTo: Date()
        )
        return String(localized: "settings.devices.offline") + " · "
            + String(format: String(localized: "settings.devices.last_synced_format"), when)
    }

    // MARK: - 配对

    @ViewBuilder
    private func inviteRow(_ model: DevicesCardModel) -> some View {
        if let invite = model.invite {
            SettingsCodeRow(
                code: invite.code,
                expiresAt: invite.expiresAt,
                info: String(localized: "settings.account.devices_add_subtitle"),
                codeIdentifier: "settings.devices.code",
                onCopy: { store.copyInvite() },
                onCancel: { store.cancelInvite() }
            )
        } else {
            SettingsRow(
                String(localized: "settings.devices.pairing_code"),
                description: String(localized: "settings.account.devices_add_subtitle")
            ) {
                ActionPill(
                    String(localized: "settings.action.create"),
                    systemImage: "plus",
                    help: String(localized: "settings.devices.create_code_hint"),
                    accessibilityLabel: String(localized: "settings.devices.create_code")
                ) {
                    store.createInvite()
                }
                .disabled(model.busy)
                .accessibilityIdentifier("settings.devices.create-code")
            }
        }
    }

    private func joinRow(_ model: DevicesCardModel) -> some View {
        SettingsFullRow {
            HStack(spacing: PillMetrics.spacing) {
                // 栏里只写这是什么;「粘贴另一台 Mac 的配对码」在提示里。
                SettingsField(
                    String(localized: "settings.devices.pairing_code"),
                    text: $joinCode,
                    onSubmit: join
                )
                .settingsExplained(
                    String(localized: "settings.devices.join_placeholder")
                        + "\n" + String(localized: "settings.devices.only_this")
                )
                .accessibilityIdentifier("settings.devices.join-code")

                if model.busy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: PillMetrics.height, height: PillMetrics.height)
                }
                ActionPill(
                    String(localized: "settings.devices.join"),
                    systemImage: "arrow.right",
                    action: join
                )
                .disabled(model.busy || joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.devices.join")
            }
            if let joinedWith {
                SettingsStatus(
                    String(format: String(localized: "settings.devices.joined_format"), joinedWith),
                    systemImage: "checkmark.circle.fill",
                    tint: .signalGreen
                )
            }
        }
    }

    private func join() {
        let code = joinCode
        joinedWith = nil
        Task {
            guard let joined = await store.join(code: code) else { return }
            joinCode = ""
            if joined.purpose == .backup {
                // 备份码:这台开始保管那台的备份;恢复码:正在把那一份合进来。
                ToastCenter.shared.success(String(
                    format: String(localized: joined.restoring ? "backup.restoring_format" : "backup.holding_format"),
                    joined.label
                ))
                await store.refreshBackup()
                return
            }
            if joined.purpose == .topic, let notebook = joined.notebookId {
                // 粘贴的是协作主题的码:加入之后直接去那个主题。
                ToastCenter.shared.success(String(
                    format: String(localized: "topic.collab.joined_format"), joined.label
                ))
                MainNavigationStore.shared.openTopicWorkspace(notebookID: notebook)
                return
            }
            joinedWith = joined.inviterName.isEmpty
                ? String(localized: "settings.devices.unnamed")
                : joined.inviterName
        }
    }

    static func countdown(until end: Date, now: Date) -> String {
        SettingsCodeRow.countdown(until: end, now: now)
    }
}

/// 一台别的 Mac 在不在线:一个点、一个词。怎么连上的、上次什么时候同步,
/// 在提示里(`DevicesSettingsSection.presence`)。
struct DevicePresenceStatus: View {
    let device: FfiSyncDevice

    var body: some View {
        SettingsStatus(
            String(localized: device.connected ? "settings.devices.online" : "settings.devices.offline"),
            systemImage: device.connected ? "circle.fill" : "circle",
            tint: device.connected ? .signalGreen : .textTertiary,
            help: DevicesSettingsSection.presence(device)
        )
    }
}
