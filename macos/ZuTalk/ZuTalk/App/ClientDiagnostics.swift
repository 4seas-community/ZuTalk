import Foundation

/// App-side events that belong in rust.log beside the core's own lines.
///
/// The app's `Logger` reaches only the system log, which drops info lines
/// within minutes and has to be read with `log show`. Two failures were
/// reconstructed from it a day late: a microphone engine
/// macOS stopped that nobody restarted, and a main thread frozen for twenty
/// seconds. Events like those are written here instead. Plain facts only —
/// never transcript text, audio, or credentials.
enum ClientDiagnostics {
    private final class Sink: @unchecked Sendable {
        nonisolated private let lock = NSLock()
        /// Guarded by `lock`.
        nonisolated(unsafe) private var core: ZuTalkCore?
        nonisolated let queue = DispatchQueue(label: "xyz.voice.zutalk.client-diagnostics", qos: .utility)

        nonisolated func set(_ core: ZuTalkCore) {
            lock.lock()
            self.core = core
            lock.unlock()
        }

        nonisolated func current() -> ZuTalkCore? {
            lock.lock()
            defer { lock.unlock() }
            return core
        }
    }

    nonisolated private static let sink = Sink()

    /// Called once, when the core is created.
    nonisolated static func install(core: ZuTalkCore) {
        sink.set(core)
    }

    /// Records `message` under `category`. Safe from any thread; the write
    /// happens on a utility queue so the caller never waits on the file.
    nonisolated static func record(category: String, _ message: String) {
        guard let core = sink.current() else { return }
        sink.queue.async {
            core.recordClientDiagnostic(category: category, message: message)
        }
    }

    /// Like `record`, but returns only after the line is written. For a
    /// caller that must not lose the line, such as one about to block.
    nonisolated static func recordNow(category: String, _ message: String) {
        guard let core = sink.current() else { return }
        sink.queue.sync {
            core.recordClientDiagnostic(category: category, message: message)
        }
    }
}
