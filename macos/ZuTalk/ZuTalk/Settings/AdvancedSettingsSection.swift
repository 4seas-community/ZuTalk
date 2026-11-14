// AdvancedSettingsSection.swift
// 设置 › 高级:大多数人用不到的五件事 —— 自己的 Soniox 密钥、自己的 DeepSeek
// 密钥、分享出去的链接、备份、诊断信息。每一件一个小标题;要让人读得到的告知
// 在标题旁边的 ⓘ 里。
//
// 这一节是供应商和模型的名字唯一出现的地方(docs/product/interface-layers.md):
// 用邀请码的人一辈子不用认识它们;要用自己密钥的人、要报问题的人,在这里都
// 找得到。没有哪样功能因为进了这一节而少了。

import SwiftUI

struct AdvancedSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // 「大多数人用不到这一页」不印在标题下面(另外两页的标题下面也没有
            // 句子):悬停在标题上、读屏读到标题的时候说。
            SettingsPageHeader(title: String(localized: "settings.section.advanced_name"))
                .help(String(localized: "settings.advanced.subtitle"))
                .accessibilityHint(Text(String(localized: "settings.advanced.subtitle")))

            ProviderSettingsView(scope: .captions)

            ProviderSettingsView(scope: .languageModel)

            SharingSettingsSection()

            SettingsGroup(
                title: String(localized: "backup.title"),
                subtitle: String(localized: "backup.subtitle"),
                info: BackupSettingsCard.howBackupWorks
            ) {
                BackupSettingsCard()
            }

            SettingsDiagnosticsCard()
        }
    }
}

// MARK: - 诊断信息

/// 只读的几行:哪一版、谁在转录、用的哪个模型、网络通不通、正在录的那一场
/// 开了几条连接、落后多少。标题那一头一颗「复制」,把这几行一起拷走 —— 报
/// 问题的人不用一行一行选。
///
/// 录音页上不再写供应商和模型的名字,也不再报落后的秒数和连接数 —— 那些对
/// 录音的人没有用。它们留在这里,给报问题的人和帮着看问题的人。名字和模型
/// 都从核心的描述里读,Swift 里不存第二份:存两份迟早对不上,界面会说出一个
/// 核心并没有在用的模型。
struct SettingsDiagnosticsCard: View {
    @ObservedObject private var engineStore = NotebookCaptureEnginePresentationStore.shared
    @ObservedObject private var modelStore = LanguageModelPresentationStore.shared
    @ObservedObject private var network = NetworkReachability.shared
    @Environment(\.settingsFixture) private var fixture

    var body: some View {
        SettingsGroup(
            title: String(localized: "settings.diagnostics.title"),
            subtitle: String(localized: "settings.diagnostics.subtitle"),
            accessory: AnyView(copyPill)
        ) {
            SettingsCard {
                ForEach(Array(fixedRows.enumerated()), id: \.offset) { _, line in
                    row(line.label, line.value)
                    SettingsRowDivider()
                }
                // 录音的 store 每来一帧就发一次变化;这一页不跟着它重画,
                // 两秒自己去看一眼就够了。
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    row(String(localized: "settings.diagnostics.recording"), LiveConnectionFacts.current().text)
                }
            }
            .accessibilityIdentifier("settings.diagnostics")
        }
        .onAppear {
            guard fixture == nil else { return }
            engineStore.refresh()
            modelStore.refresh()
        }
    }

    private var copyPill: some View {
        ActionPill(
            String(localized: "settings.action.copy"),
            systemImage: "doc.on.doc",
            style: .quiet,
            help: String(localized: "settings.diagnostics.subtitle")
        ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                DiagnosticLine.text(
                    fixedRows + [DiagnosticLine(
                        label: String(localized: "settings.diagnostics.recording"),
                        value: LiveConnectionFacts.current().text
                    )]
                ),
                forType: .string
            )
            ToastCenter.shared.success(String(localized: "settings.action.copied"))
        }
        .accessibilityIdentifier("settings.diagnostics.copy")
    }

    /// 不随录音变的那几行。
    private var fixedRows: [DiagnosticLine] {
        [
            DiagnosticLine(
                label: String(localized: "settings.updates.current_version"),
                value: GeneralSettingsSection.versionDisplay
            ),
            DiagnosticLine(
                label: String(localized: "settings.diagnostics.live_engine"),
                value: engineStore.engine.realtimeSummary
            ),
            DiagnosticLine(
                label: String(localized: "settings.diagnostics.refine_engine"),
                value: engineStore.engine.postStopSummary
            ),
            DiagnosticLine(
                label: String(localized: "settings.diagnostics.cleanup_model"),
                value: modelSummary
            ),
            DiagnosticLine(
                label: String(localized: "settings.diagnostics.network"),
                value: String(localized: network.isOffline
                    ? "settings.diagnostics.network_offline"
                    : "settings.diagnostics.network_online")
            ),
        ]
    }

    private var modelSummary: String {
        let engine = modelStore.engine
        return engine.providerDisplayName == engine.modelId
            ? engine.modelId
            : engine.providerDisplayName + " · " + engine.modelId
    }

    private func row(_ title: String, _ value: String) -> some View {
        SettingsRow(title) {
            SettingsValue(value)
        }
    }
}

/// 诊断信息的一行:名字和值。
struct DiagnosticLine: Equatable {
    var label: String
    var value: String

    /// 拷走的样子:一行一条,「名字: 值」。
    static func text(_ lines: [DiagnosticLine]) -> String {
        lines.map { $0.label + ": " + $0.value }.joined(separator: "\n")
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
