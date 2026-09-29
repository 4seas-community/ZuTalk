// DevicesSettingsSection.swift
// 设置 › 设备:自己的几台 Mac 之间同步。打开、给这台起名、看有哪几台、
// 加一台、移除一台。
//
// 配对是两台之间的事:一台生成配对码,另一台输入。两个动作放在同一张卡片里,
// 因为用户站在哪台 Mac 前面都一样找得到。

import SwiftUI

struct DevicesSettingsSection: View {
    @ObservedObject private var store = DeviceSyncStore.shared
    @ObservedObject private var nearby = NearbyStore.shared
    @State private var nameDraft = ""
    @State private var joinCode = ""
    @State private var joinedWith: String?
    @State private var removing: FfiSyncDevice?
    @State private var confirmingLeave = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SettingsPageHeader(
                title: String(localized: "settings.section.devices_name"),
                subtitle: String(localized: "settings.devices.subtitle")
            )

            SettingsCard(title: String(localized: "settings.devices.sync_title")) {
                SettingsRow(
                    String(localized: "settings.devices.enable"),
                    description: String(localized: "settings.devices.enable_hint")
                ) {
                    Toggle("", isOn: Binding(
                        get: { store.enabled },
                        set: { store.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.devices.enable")
                }
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "settings.devices.this_mac"),
                    description: String(localized: "settings.devices.this_mac_hint")
                ) {
                    TextField("", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit { store.rename(nameDraft) }
                        .accessibilityIdentifier("settings.devices.name")
                }
            }

            if store.enabled, store.removedFromGroup {
                SettingsCard(title: String(localized: "settings.devices.removed_title")) {
                    SettingsRow(
                        String(localized: "settings.devices.removed_title"),
                        description: String(localized: "settings.devices.removed_message")
                    ) {
                        Button(String(localized: "settings.devices.start_over")) { store.leaveGroup() }
                            .disabled(store.busy)
                            .accessibilityIdentifier("settings.devices.start-over")
                    }
                }
            }

            if store.enabled {
                SettingsCard(title: String(localized: "settings.devices.my_macs")) {
                    if store.otherDevices.isEmpty {
                        SettingsFullRow {
                            Text(String(localized: "settings.devices.only_this"))
                                .font(Font.sans12)
                                .foregroundColor(Color.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(Array(store.otherDevices.enumerated()), id: \.element.deviceId) { index, device in
                        if index > 0 { SettingsRowDivider() }
                        deviceRow(device)
                    }
                    if store.otherDevices.isEmpty == false, store.removedFromGroup == false {
                        SettingsRowDivider()
                        SettingsRow(
                            String(localized: "settings.devices.leave"),
                            description: String(localized: "settings.devices.leave_hint")
                        ) {
                            Button(String(localized: "settings.devices.leave")) { confirmingLeave = true }
                                .disabled(store.busy)
                        }
                    }
                }
                .accessibilityIdentifier("settings.devices.list")

                SettingsCard(
                    title: String(localized: "settings.devices.add_title"),
                    subtitle: String(localized: "settings.devices.add_subtitle")
                ) {
                    inviteRow
                    SettingsRowDivider()
                    joinRow
                }
            }

            SettingsCard(
                title: String(localized: "nearby.settings.title"),
                subtitle: String(localized: "nearby.settings.subtitle")
            ) {
                SettingsRow(
                    String(localized: "nearby.settings.receiving"),
                    description: String(localized: "nearby.settings.receiving_hint")
                ) {
                    Toggle("", isOn: Binding(
                        get: { nearby.receiving },
                        set: { nearby.setReceiving($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.devices.nearby-receiving")
                }
                if store.enabled, nearby.status?.running == true {
                    SettingsRowDivider()
                    SettingsFullRow {
                        Text(nearbySummary)
                            .font(Font.sans12)
                            .foregroundColor(Color.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(Font.sans12)
                    .foregroundColor(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.devices.problem")
            }

            SettingsCard(title: String(localized: "settings.devices.how")) {
                SettingsFullRow {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Label(String(localized: "settings.devices.how_direct"), systemImage: "arrow.left.arrow.right")
                        Label(String(localized: "settings.devices.how_audio"), systemImage: "waveform.slash")
                        Label(String(localized: "settings.devices.how_recording"), systemImage: "record.circle")
                        Label(String(localized: "settings.devices.how_code"), systemImage: "key")
                    }
                    .font(Font.sans12)
                    .foregroundColor(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            nameDraft = store.deviceName
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

    /// 附近看得见谁。局域网发现关着(只在开发构建里会这样)时直说。
    private var nearbySummary: String {
        guard let status = nearby.status, status.discovery else {
            return String(localized: "nearby.settings.discovery_off")
        }
        let names = status.peers.map { $0.name.isEmpty ? String(localized: "settings.devices.unnamed") : $0.name }
        guard names.isEmpty == false else { return String(localized: "nearby.settings.nobody") }
        return String(
            format: String(localized: "nearby.settings.seen_format"),
            ListFormatter.localizedString(byJoining: names)
        )
    }

    // MARK: - 设备行

    private func deviceRow(_ device: FfiSyncDevice) -> some View {
        SettingsRow(device.name.isEmpty ? String(localized: "settings.devices.unnamed") : device.name,
                    description: Self.presence(device)) {
            Button(String(localized: "settings.devices.remove")) { removing = device }
        }
    }

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
    private var inviteRow: some View {
        if let invite = store.invite {
            SettingsFullRow {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(invite.code)
                        .font(Font.mono10Medium)
                        .foregroundColor(Color.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.devices.code")
                    HStack(spacing: Spacing.sm) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(String(
                                format: String(localized: "settings.devices.code_expires_format"),
                                Self.countdown(until: invite.expiresAt, now: context.date)
                            ))
                            .font(Font.sans11)
                            .foregroundColor(Color.textTertiary)
                        }
                        Spacer()
                        Button(String(localized: "settings.devices.copy_code")) { store.copyInvite() }
                        Button(String(localized: "settings.devices.cancel_code")) { store.cancelInvite() }
                    }
                }
            }
        } else {
            SettingsRow(
                String(localized: "settings.devices.create_code"),
                description: String(localized: "settings.devices.create_code_hint")
            ) {
                Button(String(localized: "settings.devices.create_code")) { store.createInvite() }
                    .disabled(store.busy)
                    .accessibilityIdentifier("settings.devices.create-code")
            }
        }
    }

    private var joinRow: some View {
        SettingsFullRow {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    TextField(String(localized: "settings.devices.join_placeholder"), text: $joinCode)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(join)
                        .accessibilityIdentifier("settings.devices.join-code")
                    Button(String(localized: "settings.devices.join"), action: join)
                        .disabled(store.busy || joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if store.busy {
                    ProgressView().controlSize(.small)
                }
                if let joinedWith {
                    Label(
                        String(format: String(localized: "settings.devices.joined_format"), joinedWith),
                        systemImage: "checkmark.circle"
                    )
                    .font(Font.sans12)
                    .foregroundColor(Color.textSecondary)
                }
            }
        }
    }

    private func join() {
        let code = joinCode
        joinedWith = nil
        Task {
            guard let joined = await store.join(code: code) else { return }
            joinCode = ""
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
        let remaining = max(0, Int(end.timeIntervalSince(now)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
