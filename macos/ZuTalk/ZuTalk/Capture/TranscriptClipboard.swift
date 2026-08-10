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
}
