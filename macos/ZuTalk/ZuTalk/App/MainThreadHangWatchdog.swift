import Foundation

/// Notices when the main thread stops answering and takes a stack sample of
/// it while it is still stuck.
///
/// Once the main thread froze for 23 seconds during a recording,
/// two seconds after its window came back from behind a full-screen app, and
/// was force-quit. The audio path and the Rust core kept running; spindump
/// noticed the spin but took no sample, so nothing said where the main thread
/// was. This watchdog answers that the next time: a background thread pings
/// the main queue every half second, and once the main thread has not
/// answered for two seconds it runs `/usr/bin/sample` against this process
/// for three seconds and writes a line to rust.log naming the file. The
/// sample holds only call stacks and binary paths — no transcript or audio.
final class MainThreadHangWatchdog: @unchecked Sendable {
    nonisolated static let shared = MainThreadHangWatchdog()

    nonisolated private static let pingIntervalMs = 500
    nonisolated private static let hangThresholdMs = 2_000
    nonisolated private static let sampleSeconds = 3
    /// One sample per ten minutes is plenty; a hang that repeats faster than
    /// that is already explained by the first.
    nonisolated private static let minimumSampleSpacingMs = 10 * 60 * 1_000
    nonisolated private static let keptSamples = 5

    nonisolated private let lastAnswerMs = CaptureAtomicInt(0)
    nonisolated private let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private var thread: Thread?

    nonisolated private init() {}

    /// Starts once per process. `logsDirectory` is where rust.log lives.
    nonisolated func start(logsDirectory: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil, TestEnvironment.isAnyTestMode == false else { return }
        lastAnswerMs.storeRelease(Self.uptimeMs())
        let thread = Thread { [self] in run(logsDirectory: logsDirectory) }
        thread.name = "ZuTalk main-thread watchdog"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    nonisolated private func run(logsDirectory: URL) {
        var hangStartedMs: Int?
        var lastSampleMs = -Self.minimumSampleSpacingMs
        var previousTickMs = Self.uptimeMs()
        while true {
            Thread.sleep(forTimeInterval: Double(Self.pingIntervalMs) / 1_000)
            let now = Self.uptimeMs()
            // When the whole process is held back (App Nap, a debugger, the
            // machine under heavy load) this thread is late too. A late tick
            // measures nothing about the main thread; start over from now.
            let throttled = now - previousTickMs > Self.pingIntervalMs * 3
            previousTickMs = now
            let answer = lastAnswerMs
            DispatchQueue.main.async { answer.storeRelease(Self.uptimeMs()) }
            if throttled {
                lastAnswerMs.storeRelease(now)
                continue
            }

            let silentMs = now - lastAnswerMs.loadAcquire()
            if let started = hangStartedMs {
                if silentMs < Self.pingIntervalMs * 2 {
                    hangStartedMs = nil
                    ClientDiagnostics.record(
                        category: "main-thread",
                        "main thread answered again after \(now - started) ms"
                    )
                }
                continue
            }
            guard silentMs >= Self.hangThresholdMs else { continue }
            hangStartedMs = now - silentMs

            guard now - lastSampleMs >= Self.minimumSampleSpacingMs else {
                ClientDiagnostics.record(
                    category: "main-thread",
                    "main thread unresponsive for \(silentMs) ms (sampled recently; not sampling again)"
                )
                continue
            }
            lastSampleMs = now
            let file = Self.sampleFile(in: logsDirectory)
            ClientDiagnostics.recordNow(
                category: "main-thread",
                "main thread unresponsive for \(silentMs) ms; sampling it to \(file.lastPathComponent)"
            )
            let result = Self.sample(into: file)
            Self.pruneSamples(in: logsDirectory)
            ClientDiagnostics.record(
                category: "main-thread",
                "main-thread sample \(file.lastPathComponent): \(result)"
            )
        }
    }

    nonisolated private static func sampleFile(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return directory.appendingPathComponent(
            "main-thread-hang-\(formatter.string(from: Date())).txt"
        )
    }

    /// Runs `/usr/bin/sample` on this process; returns a short outcome.
    nonisolated private static func sample(into file: URL) -> String {
        let sampler = URL(fileURLWithPath: "/usr/bin/sample")
        guard FileManager.default.isExecutableFile(atPath: sampler.path) else {
            return "sample tool unavailable"
        }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = sampler
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            String(sampleSeconds),
            "10",
            "-mayDie",
            "-file",
            file.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "could not start sample: \(error.localizedDescription)"
        }
        // Symbolication takes a few seconds after sampling ends. A sampler
        // that hangs must not keep this watchdog from the next hang.
        let deadline = Date().addingTimeInterval(Double(sampleSeconds) + 30)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            return "sample did not finish in time"
        }
        return process.terminationStatus == 0
            ? "written"
            : "sample exited with status \(process.terminationStatus)"
    }

    nonisolated private static func pruneSamples(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let samples = files
            .filter { $0.lastPathComponent.hasPrefix("main-thread-hang-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in samples.dropFirst(keptSamples) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    nonisolated private static func uptimeMs() -> Int {
        // Uptime does not advance while the Mac sleeps, so a sleep is never
        // mistaken for a hang.
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
