// AdvancedSettingsSection.swift
// 设置 › 高级:大多数人用不到的五件事 —— 自己的 Soniox 密钥、自己的 DeepSeek
// 密钥、正在分享的链接、备份与恢复、诊断信息。
//
// 这一节是供应商和模型的名字唯一出现的地方(docs/product/interface-layers.md):
// 用邀请码的人一辈子不用认识它们;要用自己密钥的人、要报问题的人,在这里都
// 找得到。没有哪样功能因为进了这一节而少了。

import SwiftUI

struct AdvancedSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SettingsPageHeader(
                    title: String(localized: "settings.section.advanced_name"),
                    subtitle: String(localized: "settings.advanced.subtitle")
                )
                ProviderSettingsView(scope: .captions)
            }

            ProviderSettingsView(scope: .languageModel)

            SharingSettingsSection()

            SettingsGroup(
                title: String(localized: "settings.advanced.backup_title"),
                subtitle: String(localized: "backup.subtitle")
            ) {
                BackupSettingsCard()
            }

            SettingsDiagnosticsCard()
        }
    }
}

// MARK: - 诊断信息

/// 只读的几行:哪一版、谁在转录、用的哪个模型、网络通不通、正在录的那一场
/// 开了几条连接、落后多少。
///
/// 录音页上不再写供应商和模型的名字,也不再报落后的秒数和连接数 —— 那些对
/// 录音的人没有用。它们留在这里,给报问题的人和帮着看问题的人。名字和模型
/// 都从核心的描述里读,Swift 里不存第二份:存两份迟早对不上,界面会说出一个
/// 核心并没有在用的模型。
struct SettingsDiagnosticsCard: View {
    @ObservedObject private var engineStore = NotebookCaptureEnginePresentationStore.shared
    @ObservedObject private var modelStore = LanguageModelPresentationStore.shared
    @ObservedObject private var network = NetworkReachability.shared

    var body: some View {
        SettingsGroup(
            title: String(localized: "settings.diagnostics.title"),
            subtitle: String(localized: "settings.diagnostics.subtitle")
        ) {
            SettingsCard {
                row(String(localized: "settings.updates.current_version"), GeneralSettingsSection.versionDisplay)
                SettingsRowDivider()
                row(String(localized: "settings.diagnostics.live_engine"), engineStore.engine.realtimeSummary)
                SettingsRowDivider()
                row(String(localized: "settings.diagnostics.refine_engine"), engineStore.engine.postStopSummary)
                SettingsRowDivider()
                row(String(localized: "settings.diagnostics.cleanup_model"), modelSummary)
                SettingsRowDivider()
                row(
                    String(localized: "settings.diagnostics.network"),
                    String(localized: network.isOffline
                        ? "settings.diagnostics.network_offline"
                        : "settings.diagnostics.network_online")
                )
                SettingsRowDivider()
                // 录音的 store 每来一帧就发一次变化;这一页不跟着它重画,
                // 两秒自己去看一眼就够了。
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    row(String(localized: "settings.diagnostics.recording"), LiveConnectionFacts.current().text)
                }
            }
            .accessibilityIdentifier("settings.diagnostics")
        }
        .onAppear {
            engineStore.refresh()
            modelStore.refresh()
        }
    }

    private var modelSummary: String {
        let engine = modelStore.engine
        return engine.providerDisplayName == engine.modelId
            ? engine.modelId
            : engine.providerDisplayName + " · " + engine.modelId
    }

    private func row(_ title: String, _ value: String) -> some View {
        SettingsRow(title) {
            Text(value)
                .font(Font.mono11)
                .foregroundColor(Color.textSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// 正在录的那一场开了几条连接、最慢的一条落后几秒。
struct LiveConnectionFacts: Equatable {
    var isRecording: Bool
    var connections: Int
    /// 最慢的一条落后的整秒数;不到一秒算跟得上。
    var lagSeconds: UInt64?

    init(isRecording: Bool, lanes: [NotebookCaptureLaneHealthDTO]) {
        self.isRecording = isRecording
        connections = isRecording ? lanes.count : 0
        lagSeconds = isRecording
            ? lanes.compactMap { ActiveBilingualTranscriptStore.displayedLagSeconds($0.lagMs) }.max()
            : nil
    }

    @MainActor
    static func current() -> LiveConnectionFacts {
        let capture = ActiveBilingualTranscriptStore.shared
        return LiveConnectionFacts(
            isRecording: capture.isCaptureActive,
            lanes: Array(capture.laneTelemetry.values)
        )
    }

    var text: String {
        guard isRecording else {
            return String(localized: "settings.diagnostics.recording_none")
        }
        let count = String(
            format: String(localized: "settings.diagnostics.recording_connections_format"),
            Int64(connections)
        )
        guard connections > 0 else { return count }
        let pace = lagSeconds.map {
            String(format: String(localized: "settings.diagnostics.recording_lag_format"), Int64($0))
        } ?? String(localized: "settings.diagnostics.recording_keeping_up")
        return count + " · " + pace
    }
}
