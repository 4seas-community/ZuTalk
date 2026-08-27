import Foundation

/// The capture feature's two monolithic sources were split into per-module
/// files. Source-assertion tests keep their original corpus semantics by
/// reading the split files concatenated in the original declaration order.
enum CaptureSourceCorpus {
    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ZuTalk", isDirectory: true)

    /// Split of the former `Pages/NotebookCaptureViews.swift`.
    static let captureViewFiles = [
        "Pages/NotebookCaptureStartWorkflow.swift",
        "Pages/NotebookCaptureProfileEditorModel.swift",
        "Pages/NotebookCaptureToolbar.swift",
        "Pages/NotebookRealtimeTranscriptPage.swift",
        "Pages/NotebookCaptureSettingsView.swift",
        "Pages/NotebookRealtimeTranscriptPolicies.swift",
        "Pages/NotebookRealtimeUtteranceViews.swift",
        "Pages/CaptureStateLabel.swift",
    ]

    /// Split of the former monolithic `Capture/ActiveBilingualTranscriptStore.swift`.
    static let captureStoreFiles = [
        "Capture/CaptureContracts.swift",
        "Capture/CaptureLivePresentationPolicy.swift",
        "Capture/CaptureClient.swift",
        "Capture/CaptureHistory.swift",
        "Capture/CaptureAudioPipeline.swift",
        "Capture/ActiveBilingualTranscriptStore.swift",
    ]

    static func captureViews() throws -> String {
        try concatenate(captureViewFiles)
    }

    static func captureStore() throws -> String {
        try concatenate(captureStoreFiles)
    }

    private static func concatenate(_ relativePaths: [String]) throws -> String {
        try relativePaths
            .map { relativePath in
                try String(
                    contentsOf: sourceRoot.appendingPathComponent(relativePath),
                    encoding: .utf8
                )
            }
            .joined(separator: "\n")
    }
}
