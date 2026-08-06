// P2PSettingsSection.swift
// 分享（点对点）的传输设置。
//
// 这里只放**传输**层面的选择——中继走哪里、要不要局域网发现、本机身份是什么。
// 「谁能写」「共享哪个 Notebook」是每次共享时的决定，属于分享标签页，不在这里。
//
// 三件事必须在界面上说清楚，它们都不是能靠措辞含糊过去的：
//   1. 中继看不到内容——流量端到端加密，配不配中继都一样；
//   2. 不配中继不是故障——局域网直连本来就不需要它；
//   3. 换身份会让别人存的公钥全部失效。
//
// 设计见 docs/architecture/share-p2p.md。

import Combine
import SwiftUI

struct P2PSettingsSection: View {
    @StateObject private var viewModel = P2PSettingsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                SettingsSectionHeader(
                    title: String(localized: "settings.p2p.title"),
                    subtitle: String(localized: "settings.p2p.subtitle")
                )

                identityCard
                relayAccessCard
                relayCard
                discoveryCard
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
        }
        .onAppear { viewModel.load() }
    }

    // MARK: 本机身份

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "settings.p2p.identity"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)

            HStack(spacing: Spacing.sm) {
                Text(viewModel.endpointID.isEmpty ? "—" : viewModel.endpointID)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button(String(localized: "settings.p2p.copy_identity")) {
                    viewModel.copyIdentity()
                }
                .disabled(viewModel.endpointID.isEmpty)
                .accessibilityIdentifier("settings.p2p.copy_identity")
            }

            Text(String(localized: "settings.p2p.identity_note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
        }
    }

    // MARK: 中继准入

    /// 中继只放行登记过的 endpoint。这个状态必须看得见——登记失败时局域网直连
    /// 照常可用，只有跨网络才连不上，用户根本无从判断问题在哪。
    private var relayAccessCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: viewModel.enrollmentIcon)
                    .foregroundColor(viewModel.enrollmentTint)
                Text(viewModel.enrollmentTitle)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                if viewModel.canRetryEnrollment {
                    Button(String(localized: "settings.p2p.relay_retry")) {
                        viewModel.retryEnrollment()
                    }
                    .accessibilityIdentifier("settings.p2p.relay_retry")
                }
            }
            Text(viewModel.enrollmentHint)
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("settings.p2p.relay_access")
    }

    // MARK: 中继

    private var relayCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "settings.p2p.relay"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)

            // 一行一个地址。留空即「只走直连」——这是合法选择，不是错误状态。
            TextEditor(text: $viewModel.relayText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 64, maxHeight: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.textTertiary.opacity(0.4), lineWidth: 1)
                )
                .accessibilityIdentifier("settings.p2p.relay_field")

            Text(String(localized: "settings.p2p.relay_note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)

            HStack(spacing: Spacing.sm) {
                Button(String(localized: "settings.p2p.save")) {
                    viewModel.save()
                }
                .accessibilityIdentifier("settings.p2p.save")

                Button(String(localized: "settings.p2p.restore_default")) {
                    viewModel.restoreDefault()
                }

                if let message = viewModel.message {
                    Text(message)
                        .font(.bodySM)
                        .foregroundColor(viewModel.messageIsError ? .signalRed : .signalGreen)
                }
            }

            // 中继能看到什么，是用户最该被告知的一件事。
            Text(String(localized: "settings.p2p.relay_privacy"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
        }
    }

    // MARK: 局域网发现

    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Toggle(isOn: $viewModel.localDiscovery) {
                Text(String(localized: "settings.p2p.local_discovery"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
            }
            .onChange(of: viewModel.localDiscovery) { _, _ in viewModel.save() }
            .accessibilityIdentifier("settings.p2p.local_discovery")

            Text(String(localized: "settings.p2p.local_discovery_note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
        }
    }
}

@MainActor
final class P2PSettingsViewModel: ObservableObject {
    /// 订阅邀请码会话，登记状态一变界面就跟着变。
    @ObservedObject private var invite = CommunityInviteSession.shared
    /// 一行一个中继地址。多行文本而不是单个输入框，因为可以配多个。
    @Published var relayText: String = ""
    @Published var localDiscovery: Bool = true
    @Published private(set) var endpointID: String = ""
    @Published private(set) var message: String?
    @Published private(set) var messageIsError: Bool = false

    private var core: (any ZulangueCoreProtocol)? { CoreClient.shared.core }

    private var enrollment: CommunityInviteSession.RelayEnrollment {
        CommunityInviteSession.shared.relayEnrollment
    }

    var enrollmentIcon: String {
        switch enrollment {
        case .enrolled: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .noInvitation: return "info.circle"
        case .working, .unknown: return "clock"
        }
    }

    var enrollmentTint: Color {
        switch enrollment {
        case .enrolled: return .signalGreen
        case .failed: return .signalRed
        case .noInvitation, .working, .unknown: return .textSecondary
        }
    }

    var enrollmentTitle: String {
        switch enrollment {
        case .enrolled: return String(localized: "settings.p2p.relay_ready")
        case .failed: return String(localized: "settings.p2p.relay_not_registered")
        case .noInvitation: return String(localized: "settings.p2p.relay_needs_invite")
        case .working: return String(localized: "settings.p2p.relay_registering")
        case .unknown: return String(localized: "settings.p2p.relay_unknown")
        }
    }

    var enrollmentHint: String {
        switch enrollment {
        case .enrolled: return String(localized: "settings.p2p.relay_ready_hint")
        case .failed: return String(localized: "settings.p2p.relay_not_registered_hint")
        case .noInvitation: return String(localized: "settings.p2p.relay_needs_invite_hint")
        case .working, .unknown: return String(localized: "settings.p2p.relay_unknown_hint")
        }
    }

    var canRetryEnrollment: Bool {
        enrollment == .failed || enrollment == .unknown
    }

    func retryEnrollment() {
        Task { await CommunityInviteSession.shared.enrollCurrentShareEndpoint(force: true) }
    }

    func load() {
        guard let core else { return }
        let transport = core.shareTransport()
        relayText = transport.relayUrls.joined(separator: "\n")
        localDiscovery = transport.enableLocalDiscovery
        endpointID = (try? core.shareIdentity().endpointId) ?? ""
    }

    func save() {
        guard let core else { return }
        let urls = relayText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try core.setShareTransport(
                transport: FfiShareTransport(
                    relayUrls: urls,
                    enableLocalDiscovery: localDiscovery
                )
            )
            messageIsError = false
            message = String(localized: "settings.p2p.saved")
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
    }

    func restoreDefault() {
        guard let core else { return }
        let fallback = core.defaultShareTransport()
        relayText = fallback.relayUrls.joined(separator: "\n")
        localDiscovery = fallback.enableLocalDiscovery
        save()
    }

    func copyIdentity() {
        guard !endpointID.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpointID, forType: .string)
    }
}
