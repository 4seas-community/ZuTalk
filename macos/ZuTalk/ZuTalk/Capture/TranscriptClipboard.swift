import AppKit
import Foundation

/// macOS owns clipboard publication. Transcript selection and formatting stay
/// in Rust so this boundary only publishes the exact requested string.
@MainActor
enum TranscriptClipboard {
    @discardableResult
    static func write(
        _ text: String,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// 「复制全文」: a finished recording's whole transcript, and a word on
    /// how it went. Speaker names and language order are the core's choice,
    /// the same one export makes. Which version, when a recording has two:
    /// the one written down while recording, unless `refined` says the
    /// person is reading the refined transcript — then that one, since
    /// pasting a different text from the one on screen is a quiet error.
    @discardableResult
    static func copyWholeTranscript(
        sessionId: String,
        refined: Bool = false,
        core: (any ZuTalkCoreProtocol)? = nil,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let core = core ?? CoreClient.shared.core else {
            ToastCenter.shared.error(String(localized: "transcript.copy_all.failed"))
            return false
        }
        do {
            let text = refined
                ? try core.getSessionRefinedTranscriptClipboardText(sessionId: sessionId)
                : try core.getSessionTranscriptClipboardText(sessionId: sessionId)
            guard write(text, to: pasteboard) else {
                ToastCenter.shared.error(String(localized: "transcript.copy_all.failed"))
                return false
            }
            ToastCenter.shared.success(
                String(localized: "transcript.copy_all.done"),
                detail: String(localized: "transcript.copy_all.done_detail")
            )
            return true
        } catch CoreError.NotFound {
            // Nothing was transcribed: an audio-only recording, or one whose
            // text never arrived. Not a fault to report as one.
            ToastCenter.shared.info(String(localized: "transcript.copy_all.empty"))
            return false
        } catch {
            ToastCenter.shared.error(
                String(localized: "transcript.copy_all.failed"),
                detail: error.localizedDescription
            )
            return false
        }
    }
}
