// ExportSheet.swift
// 导出选项面板
// 权威：D5 §13

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
        VStack(alignment: .leading, spacing: 16) {
            Text("export.dialog.title")
                .font(.title2)

            GroupBox(String(localized: "export.dialog.text_format")) {
                VStack(alignment: .leading) {
                    Toggle("export.dialog.markdown", isOn: $includeMarkdown)
                    Toggle("export.dialog.srt", isOn: $includeSrt)
                    Toggle("export.dialog.vtt", isOn: $includeVtt)
                    Toggle("export.dialog.txt", isOn: $includeTxt)
                }
            }

            GroupBox(String(localized: "export.dialog.audio_group")) {
                Toggle("export.dialog.audio_include", isOn: $includeAudio)
            }

            if isExporting {
                ProgressView("export.progress")
            }

            if let err = lastError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button(String(localized: "common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "common.export.action")) { performExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExporting || !hasSelection)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private var hasSelection: Bool {
        includeMarkdown || includeSrt || includeVtt || includeTxt || includeAudio
    }

    private func performExport() {
        guard let core = CoreClient.shared.core else {
            lastError = "Core not initialized"
            ToastCenter.shared.error("Core not initialized")
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
                        ToastCenter.shared.success("Exported", detail: size)
                    }
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    lastError = String(format: String(localized: "export.error_format"), "\(error)")
                    ToastCenter.shared.error("Export failed", detail: "\(error)")
                }
            }
        }
    }
}
