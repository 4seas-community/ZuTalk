// ExportSheet.swift
// 导出面板:标题、要哪几种文件、两颗按钮。
// 权威：D5 §13
//
// 每一种文件是一颗点一下就切换的胶囊,上面只写格式的名字;「字幕」「纯文本」
// 「包含音频文件」这些说明在各自的悬停提示里
// (docs/product/interface-layers.md「界面怎么写」)。

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 导出选项面板
struct ExportSheet: View {
    let sessionId: String
    @Environment(\.dismiss) private var dismiss
    @State private var includeMarkdown = true
    @State private var includeSrt = true
    @State private var includeVtt = false
    @State private var includeTxt = false
    @State private var includeAudio = false
    @State private var isExporting = false
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(String(localized: "common.export.action"))
                .font(.titleMD)
                .foregroundColor(.textPrimary)

            PillStrip {
                formatPill("Markdown", help: "export.dialog.markdown", isOn: $includeMarkdown)
                    .accessibilityIdentifier("export.format.markdown")
                formatPill("SRT", help: "export.dialog.srt", isOn: $includeSrt)
                    .accessibilityIdentifier("export.format.srt")
                formatPill("VTT", help: "export.dialog.vtt", isOn: $includeVtt)
                    .accessibilityIdentifier("export.format.vtt")
                formatPill("TXT", help: "export.dialog.txt", isOn: $includeTxt)
                    .accessibilityIdentifier("export.format.txt")
                formatPill(
                    String(localized: "export.dialog.audio_group"),
                    help: "export.dialog.audio_include",
                    isOn: $includeAudio
                )
                .accessibilityIdentifier("export.format.audio")
            }

            if isExporting {
                StatusWord(
                    String(localized: "export.progress"),
                    systemImage: "tray.and.arrow.up",
                    isBusy: true
                )
            }

            if let err = lastError {
                StatusWord(
                    String(localized: "export.toast.failed"),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .signalRed,
                    help: err
                )
            }

            SheetButtons(
                confirm: String(localized: "common.export.action"),
                systemImage: "tray.and.arrow.up",
                identifier: "export.confirm",
                isEnabled: isExporting == false && hasSelection,
                onCancel: { dismiss() },
                onConfirm: performExport
            )
        }
        .padding(Spacing.lg)
        // Wide enough for the five formats side by side in every language.
        .frame(width: 520)
        .background(Color.bgRoot)
    }

    /// One kind of file: on is tinted and ticked. The pill carries the
    /// format's own name; what it is for is its tooltip.
    private func formatPill(
        _ name: String,
        help: String.LocalizationValue,
        isOn: Binding<Bool>
    ) -> some View {
        TogglePill(
            isOn: isOn.wrappedValue,
            on: .init(name, systemImage: "checkmark.circle.fill"),
            off: .init(name, systemImage: "circle"),
            help: String(localized: help)
        ) {
            isOn.wrappedValue.toggle()
        }
    }

    private var hasSelection: Bool {
        includeMarkdown || includeSrt || includeVtt || includeTxt || includeAudio
    }

    private func performExport() {
        guard let core = CoreClient.shared.core else {
            // These three used to be English whatever the interface language.
            lastError = String(localized: "export.toast.not_ready")
            ToastCenter.shared.error(String(localized: "export.toast.not_ready"))
            return
        }

        // 让用户选保存路径
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "session-\(sessionId.prefix(8)).zip"
        panel.message = String(localized: "export.dialog.location")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        lastError = nil

        let options = ExportZipOptions(
            includeAudio: includeAudio,
            includeMarkdown: includeMarkdown,
            includeSrt: includeSrt,
            includeVtt: includeVtt,
            includeTxt: includeTxt
        )

        let sid = sessionId
        let outputPath = url.path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outcome = try core.exportSessionZip(
                    sessionId: sid,
                    outputPath: outputPath,
                    options: options
                )
                DispatchQueue.main.async {
                    isExporting = false
                    let size = "\(outcome.bytesWritten / 1024) KB → \(url.lastPathComponent)"
                    // 供应商偶尔整段不给时间戳,那些行进不了 .srt/.vtt。
                    // 文件没法变得更好——不编时间是既定取舍——但一份 0 字节
                    // 的 .srt 配一句「导出成功」是在说假话,所以这里改口。
                    if outcome.subtitleRowsOmitted > 0 {
                        let detail = String(
                            format: String(localized: "export.subtitles_omitted_format"),
                            outcome.subtitleRowsOmitted
                        )
                        ToastCenter.shared.warning(
                            String(localized: "export.subtitles_incomplete"),
                            detail: "\(detail)\n\(size)"
                        )
                    } else {
                        ToastCenter.shared.success(
                            String(localized: "export.toast.done"),
                            detail: size
                        )
                    }
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    lastError = String(format: String(localized: "export.error_format"), "\(error)")
                    ToastCenter.shared.error(
                        String(localized: "export.toast.failed"),
                        detail: "\(error)"
                    )
                }
            }
        }
    }
}
