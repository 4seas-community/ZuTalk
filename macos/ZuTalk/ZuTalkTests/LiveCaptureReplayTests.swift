import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ZuTalk

/// Opt-in end-to-end replay of a recorded file through the whole live path:
/// the shared capture store, the real Rust core, real Soniox connections over
/// a community invitation, and the transcript page the user looks at, mounted
/// in an off-screen window so SwiftUI lays it out exactly as it would on
/// screen.
///
/// The Rust replay harness (`crates/vt-ffi/tests/lecture_replay.rs`) proves
/// the provider side keeps up. This proves the other half: whether the main
/// thread can still draw what arrives. It reports, per window of the
/// recording, how long the main queue took to answer and how far the newest
/// line on the page trails the audio that has been fed.
///
/// It runs only when `zutalk-live-replay.json` exists in the test process's
/// temporary directory (`getconf DARWIN_USER_TEMP_DIR`):
///
/// ```json
/// { "media": "/path/to/16k-mono-s16.wav", "invite_token": "/path/to/community-invite.json",
///   "languages": ["th", "zh", "en"], "out": "/path/to/report.txt", "seconds": 600}
/// ```
///
/// Run it with `CFFIXED_USER_HOME` pointed at a scratch directory so the
/// invite switch it turns on lands in a throwaway preferences domain.
@MainActor
final class LiveCaptureReplayTests: XCTestCase {
    private struct Config: Decodable {
        let media: String
        let invite_token: String
        let languages: [String]
        let out: String
        let seconds: Double?
        let trace: Bool?
        /// Mount the page after the recording has started, so it opens in
        /// language columns as it does for a notebook that has recorded before.
        let columns: Bool?
        /// Also lay out the audience subtitle window's content.
        let subtitles: Bool?
        /// Write every callback the core delivers to this JSON Lines file.
        let record: String?
    }

    func testReplayRecordedFileThroughTheLivePage() async throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zutalk-live-replay.json")
        guard let data = try? Data(contentsOf: configURL) else {
            throw XCTSkip("opt-in: no zutalk-live-replay.json in the temporary directory")
        }
        guard NSHomeDirectory().hasPrefix(FileManager.default.temporaryDirectory.path)
                || ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil
                || NSHomeDirectory().contains("scratch") else {
            throw XCTSkip("run with CFFIXED_USER_HOME so preferences stay out of the real profile")
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        let pcm = try Self.loadPCM(URL(fileURLWithPath: config.media))
        let limitMs = config.seconds.map { UInt64($0 * 1_000) } ?? UInt64(pcm.count / 32)

        // Credential: the invitation, exactly as the app uses it.
        let tokenURL = CommunityInviteSession.defaultTokenFileURL()
        try FileManager.default.createDirectory(
            at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: tokenURL)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: config.invite_token), to: tokenURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        let invite = CommunityInviteSession.shared
        invite.reloadAccessTokenForTesting()
        invite.setEnabled(true)
        XCTAssertTrue(invite.isActive, "invite token did not load")

        let core = try XCTUnwrap(CoreClient.shared.core)
        let notebook = try core.createNotebook(title: "Live replay")
        let store = ActiveBilingualTranscriptStore.shared
        store.loadProfile(notebookId: notebook.id)
        var profile = store.profileForNotebook(notebook.id)
        profile.remoteRealtimeEnabled = true
        profile.mode = config.languages.count >= 3 ? .multilingualOneWay : .twoWay
        profile.selectedLanguages = config.languages
        profile.subtitleOnlyLanguages = []
        profile.languageA = config.languages[0]
        profile.languageB = config.languages[1]
        profile.leftLanguage = config.languages[0]
        profile.rightLanguage = config.languages[1]
        profile.sendContextToSoniox = false
        _ = try store.saveProfile(profile)

        // The page, laid out for real in windows nobody sees.
        let editor = NotebookCaptureProfileEditorModel(notebookId: notebook.id)
        func offscreenWindow<Content: View>(height: CGFloat, _ content: Content) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 1_280, height: height),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: content.frame(width: 1_280, height: height))
            window.orderFrontRegardless()
            return window
        }
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        func mountPage() {
            windows.append(offscreenWindow(height: 900,
                NotebookRealtimeTranscriptPage(notebookId: notebook.id, sessionId: nil, editor: editor)
            ))
        }
        if config.columns != true { mountPage() }

        let source = ReplayAudioSource(pcm: pcm, limitMs: limitMs)
        store.replaceAudioSourceForTesting(source)
        if let record = config.record {
            store.replaceClientForTesting(try RecordingNotebookCaptureClient(
                base: RustNotebookCaptureClient(),
                recordingTo: URL(fileURLWithPath: record)
            ))
        }
        defer {
            store.replaceClientForTesting(RustNotebookCaptureClient())
            store.replaceAudioSourceForTesting(LiveNotebookCaptureAudioSource())
        }

        let lanes = config.languages.count >= 3 ? config.languages.count : 1
        _ = try await invite.prepareRealtimeCredential(laneCount: lanes)
        try await store.start(notebookId: notebook.id)
        if config.columns == true { mountPage() }
        if config.subtitles == true {
            windows.append(offscreenWindow(height: 420, SubtitleOverlayView(store: store)))
        }

        let probe = MainQueueProbe()
        probe.start()
        var storeChanges = 0
        var frameChanges = 0
        let storeSink = store.objectWillChange.sink { storeChanges += 1 }
        let frameSink = store.livePresentation.objectWillChange.sink { frameChanges += 1 }
        defer { storeSink.cancel(); frameSink.cancel() }

        var report: [String] = []
        func line(_ text: String) {
            report.append(text)
            print(text)
        }
        line("==== live page replay: \(config.languages.joined(separator: ",")) \(limitMs / 1_000)s"
            + (config.columns == true ? " columns" : " timeline")
            + (config.subtitles == true ? " + subtitles" : "") + " ====")
        line("window(s)  main p50/p95/max ms  >100ms  >500ms | page trails audio p50/max s | store/frame publishes")

        let started = Date()
        let windowSeconds = 30.0
        var nextReport = windowSeconds
        var trail: [Double] = []
        var previousStore = 0
        var previousFrame = 0
        let trace = config.trace == true
        // A recording can also end on its own — the machine sleeping ends it
        // by design — and then the feed stops with it.
        while source.isFinished == false, store.isCaptureActive {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let fedMs = Double(source.fedMs)
            // What the page has to show: the newest settled row or the live tail.
            let shown = Double((store.utterances + store.livePreviewUtterances)
                .compactMap(\.sourceEndMs).max() ?? 0)
            if ProcessInfo.processInfo.environment["LIVE_REPLAY_TRACE"] != nil || trace {
                let durableEnd = store.utterances.compactMap(\.sourceEndMs).max() ?? 0
                let preview = store.livePreviewUtterances
                print("trace fed=\(Int(fedMs)) durable=\(store.utterances.count)@\(durableEnd) preview=\(preview.count)@\(preview.map { "\($0.sourceStartMs ?? 0)-\($0.sourceEndMs ?? 0):\($0.sourceText.count)" }.joined(separator: ","))")
            }
            trail.append(max(0, fedMs - shown) / 1_000)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= nextReport {
                let main = probe.drain()
                line(String(
                    format: "%4.0f-%4.0f  %6.1f %7.1f %8.1f  %5d  %5d | %5.1f %6.1f | %d/%d",
                    nextReport - windowSeconds, nextReport,
                    main.percentile(0.5), main.percentile(0.95), main.max() ?? 0,
                    main.filter { $0 > 100 }.count, main.filter { $0 > 500 }.count,
                    trail.percentile(0.5), trail.max() ?? 0,
                    storeChanges - previousStore, frameChanges - previousFrame
                ))
                previousStore = storeChanges
                previousFrame = frameChanges
                trail.removeAll()
                nextReport += windowSeconds
            }
        }
        probe.stop()

        if store.isCaptureActive == false {
            line(String(format: "recording ended by itself at %.0fs of audio", Double(source.fedMs) / 1_000))
        }
        let stopStarted = Date()
        if store.isCaptureActive {
            try await store.stop()
        }
        line(String(format: "stop took %.1fs", Date().timeIntervalSince(stopStarted)))
        line("rows \(store.utterances.count), cues \(store.translationCues.count), gap repairs \(store.gapRepairCountForTesting)")
        await invite.settleRealtimeSession(usedSeconds: Int(limitMs / 1_000) + 1)

        try report.joined(separator: "\n").appending("\n")
            .write(toFile: config.out, atomically: true, encoding: .utf8)
    }

    /// 16 kHz mono s16le samples from a WAV file's `data` chunk.
    private static func loadPCM(_ url: URL) throws -> Data {
        let file = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= file.count {
            let id = String(decoding: file[offset..<offset + 4], as: UTF8.self)
            let size = file[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if id == "data" {
                return file.subdata(in: offset + 8..<min(file.count, offset + 8 + Int(size)))
            }
            offset += 8 + Int(size)
        }
        throw NSError(domain: "LiveCaptureReplay", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "no data chunk in the replay WAV",
        ])
    }
}

/// Feeds a file in 100 ms blocks on the wall clock, like a microphone.
@MainActor
private final class ReplayAudioSource: NotebookCaptureAudioSourcing {
    private let pcm: Data
    private let limitMs: UInt64
    private let queue = DispatchQueue(label: "live-replay.audio", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let state = ReplayFeedState()
    private(set) var preparedInputDevice: AudioInputDevice?
    var selectedInputDeviceUID: String? { "live-replay" }

    init(pcm: Data, limitMs: UInt64) {
        self.pcm = pcm
        self.limitMs = limitMs
    }

    var fedMs: UInt64 { state.fedMs }
    var isFinished: Bool { state.isFinished }

    func prepare() async throws {
        preparedInputDevice = try resolveInputDevice(uid: nil)
    }

    func resolveInputDevice(uid: String?) throws -> AudioInputDevice {
        AudioInputDevice(deviceID: 1, uid: "live-replay", name: "Live replay")
    }

    func commitInputDeviceSelection(uid: String?, device: AudioInputDevice) {
        preparedInputDevice = device
    }

    func subscribe(
        inputDevice: AudioInputDevice,
        onAudio: @escaping @Sendable (Data) -> Void,
        onOverflow: @escaping @Sendable () -> Void
    ) throws -> NotebookCaptureAudioToken {
        let pcm = pcm
        let limitBytes = min(pcm.count, Int(limitMs) * 32)
        let state = state
        let started = DispatchTime.now()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler {
            // Catch up to the wall clock in whole 100 ms blocks.
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            while state.fedMs + 100 <= elapsedMs {
                let from = Int(state.fedMs) * 32
                guard from < limitBytes else {
                    state.isFinished = true
                    return
                }
                onAudio(pcm.subdata(in: from..<min(limitBytes, from + 3_200)))
                state.fedMs += 100
            }
        }
        self.timer = timer
        timer.resume()
        return NotebookCaptureAudioToken(id: UUID())
    }

    func unsubscribe(_ token: NotebookCaptureAudioToken) -> NotebookCaptureInterruptReason? {
        timer?.cancel()
        timer = nil
        return nil
    }
}

private final class ReplayFeedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _fedMs: UInt64 = 0
    private var _finished = false
    var fedMs: UInt64 {
        get { lock.withLock { _fedMs } }
        set { lock.withLock { _fedMs = newValue } }
    }
    var isFinished: Bool {
        get { lock.withLock { _finished } }
        set { lock.withLock { _finished = newValue } }
    }
}

/// How long the main queue takes to run a block posted from another thread,
/// sampled every 50 ms. This is the delay every UI update waits behind.
private final class MainQueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private var running = false
    private let thread = DispatchQueue(label: "live-replay.probe")

    func start() {
        lock.withLock { running = true }
        thread.async { [self] in
            while lock.withLock({ running }) {
                let posted = DispatchTime.now().uptimeNanoseconds
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    let waited = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000
                    self.lock.withLock { self.samples.append(waited) }
                    answered.signal()
                }
                answered.wait()
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func stop() { lock.withLock { running = false } }

    func drain() -> [Double] {
        lock.withLock {
            defer { samples.removeAll() }
            return samples
        }
    }
}

private extension Array where Element == Double {
    func percentile(_ p: Double) -> Double {
        guard isEmpty == false else { return 0 }
        let sorted = self.sorted()
        return sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}

/// The same live surfaces fed from a recorded stream instead of Soniox, at a
/// chosen speed, so a two-hour meeting can be measured in a fraction of that
/// and without spending invitation time. Runs only when
/// `zutalk-live-replay-offline.json` is in the temporary directory:
///
/// ```json
/// { "stream": "/path/to/stream.jsonl", "languages": ["th", "zh", "en"],
///   "out": "/path/to/report.txt", "speed": 8, "columns": true, "subtitles": true }
/// ```
///
/// Build a long stream from a recording with `extend_stream.py`. The core
/// records locally underneath; the stream supplies what the provider said.
@MainActor
final class LiveCaptureOfflineReplayTests: XCTestCase {
    private struct Config: Decodable {
        let stream: String
        let languages: [String]
        let out: String
        let speed: Double?
        let columns: Bool?
        let subtitles: Bool?
        let minutes: Double?
    }

    func testReplayRecordedStreamThroughTheLiveSurfaces() async throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zutalk-live-replay-offline.json")
        guard let data = try? Data(contentsOf: configURL) else {
            throw XCTSkip("opt-in: no zutalk-live-replay-offline.json in the temporary directory")
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        let speed = max(config.speed ?? 1, 0.1)
        let languages = config.languages

        let core = try XCTUnwrap(CoreClient.shared.core)
        let notebook = try core.createNotebook(title: "Offline replay")
        let rust = RustNotebookCaptureClient()
        var local = try rust.getNotebookCaptureProfile(notebookId: notebook.id)
        local.remoteRealtimeEnabled = false
        local.mode = .transcriptionOnly
        local.selectedLanguages = [languages[0]]
        local.subtitleOnlyLanguages = []
        local.sendContextToSoniox = false
        _ = try rust.updateNotebookCaptureProfile(local)

        let replay = ReplayingNotebookCaptureClient(base: rust) { profile in
            var profile = profile
            profile.remoteRealtimeEnabled = true
            profile.mode = languages.count >= 3 ? .multilingualOneWay : .twoWay
            profile.selectedLanguages = languages
            profile.languageA = languages[0]
            profile.languageB = languages[1]
            profile.leftLanguage = languages[0]
            profile.rightLanguage = languages[1]
            return profile
        }
        let store = ActiveBilingualTranscriptStore.shared
        store.replaceClientForTesting(replay)
        store.replaceAudioSourceForTesting(SilentReplayAudioSource())
        defer {
            store.replaceClientForTesting(RustNotebookCaptureClient())
            store.replaceAudioSourceForTesting(LiveNotebookCaptureAudioSource())
        }

        let editor = NotebookCaptureProfileEditorModel(notebookId: notebook.id)
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        func mount<Content: View>(height: CGFloat, _ content: Content) {
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 1_280, height: height),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: content.frame(width: 1_280, height: height))
            window.orderFrontRegardless()
            windows.append(window)
        }
        let page = NotebookRealtimeTranscriptPage(notebookId: notebook.id, sessionId: nil, editor: editor)
        if config.columns != true { mount(height: 900, page) }
        try await store.start(notebookId: notebook.id)
        let sessionId = try XCTUnwrap(replay.sessionId)
        if config.columns == true { mount(height: 900, page) }
        if config.subtitles == true { mount(height: 420, SubtitleOverlayView(store: store)) }

        let feed = OfflineReplayFeed(
            path: config.stream,
            sessionId: sessionId,
            speed: speed,
            limitMs: config.minutes.map { $0 * 60_000 }
        )
        let probe = OfflineMainQueueProbe()
        probe.start()
        var report: [String] = []
        func line(_ text: String) {
            report.append(text)
            print(text)
        }
        line("==== offline replay: \(languages.joined(separator: ",")) at \(speed)x"
            + (config.columns == true ? " columns" : " timeline")
            + (config.subtitles == true ? " + subtitles" : "") + " ====")
        line("recording min  main p50/p95/max ms  >100ms | delivery late p50/p95/max ms | rows  frames")

        var frames = 0
        let frameSink = store.timeline.$frame.sink { _ in frames += 1 }
        defer { frameSink.cancel() }
        let windowRecordingMs = 5 * 60_000.0
        var nextWindow = windowRecordingMs
        var late: [Double] = []
        var previousFrames = 0
        while let batch = await feed.next() {
            late.append(batch.lateMs)
            for callback in batch.callbacks { replay.deliver(callback) }
            if batch.recordingMs >= nextWindow {
                let main = probe.drain()
                line(String(
                    format: "%5.0f-%5.0f  %6.1f %7.1f %8.1f  %5d | %7.1f %7.1f %8.1f | %4d  %5d",
                    (nextWindow - windowRecordingMs) / 60_000, nextWindow / 60_000,
                    main.offlinePercentile(0.5), main.offlinePercentile(0.95), main.max() ?? 0,
                    main.filter { $0 > 100 }.count,
                    late.offlinePercentile(0.5), late.offlinePercentile(0.95), late.max() ?? 0,
                    store.utterances.count, frames - previousFrames
                ))
                previousFrames = frames
                late.removeAll()
                nextWindow += windowRecordingMs
            }
        }
        probe.stop()
        line("delivered \(feed.delivered) callbacks, skipped \(feed.skippedPreviews) stale previews, gap repairs \(store.gapRepairCountForTesting)")
        try await store.stop()
        try report.joined(separator: "\n").appending("\n")
            .write(toFile: config.out, atomically: true, encoding: .utf8)
    }
}

/// Reads the stream off the main thread and hands back what is due, in
/// order. When delivery falls behind, previews that a newer preview already
/// replaces are dropped — the core's mailbox does the same — but every
/// event is delivered.
private final class OfflineReplayFeed: @unchecked Sendable {
    struct Batch {
        let callbacks: [LiveCaptureRecordedCallback]
        let lateMs: Double
        let recordingMs: Double
    }

    private let reader: OfflineLineReader?
    private let placeholder = Data("REPLAY-SESSION".utf8)
    private let sessionId: Data
    private let speed: Double
    private let limitMs: Double?
    private let started = DispatchTime.now()
    private var pending: LiveCaptureRecordedCallback?
    private(set) var delivered = 0
    private(set) var skippedPreviews = 0

    init(path: String, sessionId: String, speed: Double, limitMs: Double?) {
        reader = OfflineLineReader(path: path)
        self.sessionId = Data(sessionId.utf8)
        self.speed = speed
        self.limitMs = limitMs
    }

    private var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
    }

    private func decode() -> LiveCaptureRecordedCallback? {
        while let line = reader?.next() {
            let retargeted = line.replacingOccurrences(of: placeholder, with: sessionId)
            if let callback = try? JSONDecoder().decode(LiveCaptureRecordedCallback.self, from: retargeted) {
                return callback
            }
        }
        return nil
    }

    func next() async -> Batch? {
        let first: LiveCaptureRecordedCallback
        if let pending {
            first = pending
            self.pending = nil
        } else {
            guard let decoded = await Task.detached(operation: { self.decode() }).value else { return nil }
            first = decoded
        }
        if let limitMs, first.atMs > limitMs { return nil }
        let dueMs = first.atMs / speed
        let wait = dueMs - elapsedMs
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
        let lateMs = max(0, elapsedMs - dueMs)
        // Everything else already due goes with it.
        var callbacks = [first]
        while true {
            guard let next = await Task.detached(operation: { self.decode() }).value else { break }
            if next.atMs / speed > elapsedMs {
                pending = next
                break
            }
            if next.event == nil, let last = callbacks.last, last.event == nil {
                callbacks[callbacks.count - 1] = next
                skippedPreviews += 1
            } else {
                callbacks.append(next)
            }
        }
        delivered += callbacks.count
        return Batch(callbacks: callbacks, lateMs: lateMs, recordingMs: callbacks.last?.atMs ?? first.atMs)
    }
}

private final class OfflineLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var atEnd = false

    init?(path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = handle
    }

    func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            if atEnd {
                defer { buffer.removeAll() }
                return buffer.isEmpty ? nil : buffer
            }
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { atEnd = true } else { buffer.append(chunk) }
        }
    }
}

@MainActor
private final class SilentReplayAudioSource: NotebookCaptureAudioSourcing {
    private(set) var preparedInputDevice: AudioInputDevice?
    var selectedInputDeviceUID: String? { "offline-replay" }
    func prepare() async throws { preparedInputDevice = try resolveInputDevice(uid: nil) }
    func resolveInputDevice(uid: String?) throws -> AudioInputDevice {
        AudioInputDevice(deviceID: 1, uid: "offline-replay", name: "Offline replay")
    }
    func commitInputDeviceSelection(uid: String?, device: AudioInputDevice) { preparedInputDevice = device }
    func subscribe(
        inputDevice: AudioInputDevice,
        onAudio: @escaping @Sendable (Data) -> Void,
        onOverflow: @escaping @Sendable () -> Void
    ) throws -> NotebookCaptureAudioToken {
        NotebookCaptureAudioToken(id: UUID())
    }
    func unsubscribe(_ token: NotebookCaptureAudioToken) -> NotebookCaptureInterruptReason? { nil }
}

private final class OfflineMainQueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private var running = false
    private let queue = DispatchQueue(label: "offline-replay.probe")

    func start() {
        lock.withLock { running = true }
        queue.async { [self] in
            while lock.withLock({ running }) {
                let posted = DispatchTime.now().uptimeNanoseconds
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    let waited = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000
                    self.lock.withLock { self.samples.append(waited) }
                    answered.signal()
                }
                answered.wait()
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func stop() { lock.withLock { running = false } }

    func drain() -> [Double] {
        lock.withLock {
            defer { samples.removeAll() }
            return samples
        }
    }
}

private extension Array where Element == Double {
    func offlinePercentile(_ p: Double) -> Double {
        guard isEmpty == false else { return 0 }
        let sorted = self.sorted()
        return sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}

private extension Data {
    func replacingOccurrences(of target: Data, with replacement: Data) -> Data {
        var result = Data()
        result.reserveCapacity(count)
        var searchStart = startIndex
        while let range = self.range(of: target, in: searchStart..<endIndex) {
            result.append(self[searchStart..<range.lowerBound])
            result.append(replacement)
            searchStart = range.upperBound
        }
        result.append(self[searchStart..<endIndex])
        return result
    }
}
