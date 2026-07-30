import AVFoundation
import Foundation
import Synchronization
import os

/// Stateful mono PCM resampler used by the microphone tap.
///
/// A causal, Blackman-windowed sinc low-pass filter provides anti-aliasing;
/// fractional output positions preserve the exact input/output rate ratio.
/// History and phase are retained across calls, so arbitrary AVAudioEngine
/// buffer boundaries cannot duplicate or drop samples.
final class StreamingS16Resampler {
    let inputSampleRate: Double
    let outputSampleRate: Double

    private let tapCount: Int
    private let step: Double
    private let cutoff: Double
    private let delay: Double
    private let window: [Double]

    private var history: [Float] = []
    private var historyStartIndex: Int64 = 0
    private var totalInputSamples: Int64 = 0
    private var nextOutputIndex: Int64 = 0

    init(inputSampleRate: Double, outputSampleRate: Double = 16_000, tapCount: Int = 64) {
        precondition(inputSampleRate > 0)
        precondition(outputSampleRate > 0)
        precondition(tapCount >= 16 && tapCount.isMultiple(of: 2))
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.tapCount = tapCount
        step = inputSampleRate / outputSampleRate
        // Leave a small transition band below the target Nyquist frequency.
        cutoff = 0.5 * min(1, outputSampleRate / inputSampleRate) * 0.94
        delay = Double(tapCount - 1) / 2
        window = (0..<tapCount).map { index in
            let phase = 2 * Double.pi * Double(index) / Double(tapCount - 1)
            return 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)
        }
        history.reserveCapacity(tapCount * 2)
    }

    func process(_ samples: UnsafeBufferPointer<Float>) -> [Int16] {
        guard samples.isEmpty == false else { return [] }
        history.append(contentsOf: samples)
        totalInputSamples += Int64(samples.count)

        let nextOutputPosition = Double(nextOutputIndex) * step
        let estimatedCount = Int(ceil(
            (Double(totalInputSamples) - nextOutputPosition) / step
        ))
        var output: [Int16] = []
        output.reserveCapacity(max(0, estimatedCount))

        while true {
            // Derive each phase from the integer output index. Repeatedly
            // adding a fractional step (for example 44_100 / 16_000) can
            // accumulate just enough error to emit a 16_001st sample.
            let nextOutputPosition = Double(nextOutputIndex) * step
            guard nextOutputPosition < Double(totalInputSamples) else { break }
            let baseIndex = Int64(floor(nextOutputPosition))
            let fraction = nextOutputPosition - Double(baseIndex)
            var filtered = 0.0
            var coefficientSum = 0.0

            for tap in 0..<tapCount {
                let sourceIndex = baseIndex - Int64(tap)
                let distance = Double(tap) + fraction - delay
                let coefficient = 2 * cutoff
                    * Self.sinc(2 * cutoff * distance)
                    * window[tap]
                coefficientSum += coefficient

                let localIndex = sourceIndex - historyStartIndex
                if localIndex >= 0, localIndex < Int64(history.count) {
                    filtered += Double(history[Int(localIndex)]) * coefficient
                }
            }

            if abs(coefficientSum) > 1e-12 {
                filtered /= coefficientSum
            }
            let clamped = max(-1.0, min(1.0, filtered))
            output.append(Int16(clamping: Int((clamped * 32_767).rounded())))
            nextOutputIndex += 1
        }

        discardUnneededHistory()
        return output
    }

    func process(_ samples: [Float]) -> [Int16] {
        samples.withUnsafeBufferPointer(process)
    }

    private func discardUnneededHistory() {
        let nextOutputPosition = Double(nextOutputIndex) * step
        let earliestNeeded = Int64(floor(nextOutputPosition)) - Int64(tapCount - 1)
        let removable = min(
            max(0, earliestNeeded - historyStartIndex),
            Int64(history.count)
        )
        guard removable > 0 else { return }
        history.removeFirst(Int(removable))
        historyStartIndex += removable
    }

    private static func sinc(_ value: Double) -> Double {
        guard abs(value) > 1e-12 else { return 1 }
        let angle = Double.pi * value
        return sin(angle) / angle
    }
}

/// Fixed-storage SPSC queue between the AVAudioEngine tap and one capture
/// worker. The producer path performs only atomic loads/stores and a bounded
/// memcpy into memory allocated before the tap is installed.
final class MicrophoneCaptureSPSCRing: @unchecked Sendable {
    enum EnqueueResult: Equatable, Sendable {
        case accepted
        case closed
        case overflow
    }

    let capacity: Int
    let maximumFramesPerSlot: Int

    private let sampleStorage: UnsafeMutablePointer<Float>
    private let frameCounts: UnsafeMutablePointer<Int>
    private let sampleTimes: UnsafeMutablePointer<Int64>
    private let writeSequence = Atomic<Int>(0)
    private let readSequence = Atomic<Int>(0)
    private let producerInFlight = Atomic<Int>(0)
    private let accepting = Atomic<Bool>(true)
    private let overflowNotificationPending = Atomic<Bool>(false)
    private let overflowDetected = Atomic<Bool>(false)

    init(capacity: Int, maximumFramesPerSlot: Int) {
        precondition(capacity > 0)
        precondition(maximumFramesPerSlot > 0)
        self.capacity = capacity
        self.maximumFramesPerSlot = maximumFramesPerSlot
        sampleStorage = .allocate(capacity: capacity * maximumFramesPerSlot)
        frameCounts = .allocate(capacity: capacity)
        sampleTimes = .allocate(capacity: capacity)
        sampleStorage.initialize(repeating: 0, count: capacity * maximumFramesPerSlot)
        frameCounts.initialize(repeating: 0, count: capacity)
        sampleTimes.initialize(repeating: 0, count: capacity)
    }

    deinit {
        sampleStorage.deinitialize(count: capacity * maximumFramesPerSlot)
        frameCounts.deinitialize(count: capacity)
        sampleTimes.deinitialize(count: capacity)
        sampleStorage.deallocate()
        frameCounts.deallocate()
        sampleTimes.deallocate()
    }

    /// Realtime producer entrypoint. There is exactly one AVAudioEngine tap.
    @discardableResult
    func enqueue(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64) -> EnqueueResult {
        _ = producerInFlight.wrappingAdd(1, ordering: .acquiringAndReleasing)
        defer {
            let previous = producerInFlight
                .wrappingSubtract(1, ordering: .acquiringAndReleasing)
                .oldValue
            precondition(previous > 0, "microphone ring producer count underflow")
        }

        guard accepting.load(ordering: .acquiring) else { return .closed }
        guard samples.isEmpty == false else { return .closed }
        guard samples.count <= maximumFramesPerSlot else {
            return closeForOverflow()
        }

        let write = writeSequence.load(ordering: .relaxed)
        let read = readSequence.load(ordering: .acquiring)
        guard write - read < capacity else {
            return closeForOverflow()
        }

        let slot = write % capacity
        sampleStorage
            .advanced(by: slot * maximumFramesPerSlot)
            .update(from: samples.baseAddress!, count: samples.count)
        frameCounts[slot] = samples.count
        sampleTimes[slot] = sampleTime
        writeSequence.store(write + 1, ordering: .releasing)
        return .accepted
    }

    /// Single-worker consumer entrypoint. The slot is not released back to the
    /// tap until `body` returns, so the provided pointer remains stable.
    @discardableResult
    func consume(
        _ body: (UnsafeBufferPointer<Float>, Int64) -> Void
    ) -> Bool {
        let read = readSequence.load(ordering: .relaxed)
        let write = writeSequence.load(ordering: .acquiring)
        guard read < write else { return false }

        let slot = read % capacity
        let count = frameCounts[slot]
        let samples = UnsafeBufferPointer(
            start: sampleStorage.advanced(by: slot * maximumFramesPerSlot),
            count: count
        )
        body(samples, sampleTimes[slot])
        readSequence.store(read + 1, ordering: .releasing)
        return true
    }

    func close() {
        accepting.store(false, ordering: .releasing)
    }

    /// Claimed by the worker, never by the realtime producer. The compare and
    /// exchange makes the overflow callback exactly-once.
    func claimOverflowNotification() -> Bool {
        overflowNotificationPending.compareExchange(
            expected: true,
            desired: false,
            ordering: .acquiringAndReleasing
        ).exchanged
    }

    var isClosedAndDrained: Bool {
        guard accepting.load(ordering: .acquiring) == false,
              producerInFlight.load(ordering: .acquiring) == 0
        else { return false }
        return readSequence.load(ordering: .acquiring)
            == writeSequence.load(ordering: .acquiring)
    }

    var pendingCountForTesting: Int {
        writeSequence.load(ordering: .acquiring)
            - readSequence.load(ordering: .acquiring)
    }

    var didOverflow: Bool {
        overflowDetected.load(ordering: .acquiring)
    }

    private func closeForOverflow() -> EnqueueResult {
        let transition = accepting.compareExchange(
            expected: true,
            desired: false,
            ordering: .acquiringAndReleasing
        )
        guard transition.exchanged else { return .closed }
        overflowDetected.store(true, ordering: .releasing)
        overflowNotificationPending.store(true, ordering: .releasing)
        return .overflow
    }
}

enum MicrophoneCaptureTerminalReason: Equatable, Sendable {
    case overflow
}

/// High-priority serial consumer for one microphone-capture generation.
/// Resampling, Data allocation, and callback delivery all happen here, never
/// in the AVAudioEngine tap.
final class MicrophoneCaptureWorker: @unchecked Sendable {
    let generation: UInt64
    let ring: MicrophoneCaptureSPSCRing

    private let inputSampleRate: Double
    private let resampler: StreamingS16Resampler
    private let onAudio: @Sendable (UInt64, Data, UInt64) -> Void
    private let onOverflow: @Sendable (UInt64) -> Void
    private let started = Atomic<Bool>(false)
    private let completion = DispatchGroup()
    private var thread: Thread?

    init(
        generation: UInt64,
        inputSampleRate: Double,
        ringCapacity: Int,
        maximumFramesPerSlot: Int,
        onAudio: @escaping @Sendable (UInt64, Data, UInt64) -> Void,
        onOverflow: @escaping @Sendable (UInt64) -> Void
    ) {
        precondition(inputSampleRate > 0)
        self.generation = generation
        self.inputSampleRate = inputSampleRate
        ring = MicrophoneCaptureSPSCRing(
            capacity: ringCapacity,
            maximumFramesPerSlot: maximumFramesPerSlot
        )
        resampler = StreamingS16Resampler(inputSampleRate: inputSampleRate)
        self.onAudio = onAudio
        self.onOverflow = onOverflow
    }

    func start() {
        let transition = started.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        guard transition.exchanged else { return }

        completion.enter()
        let thread = Thread { [self] in
            defer { completion.leave() }
            run()
        }
        thread.name = "Zulangue microphone DSP \(generation)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Realtime producer entrypoint.
    @discardableResult
    func enqueue(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64) -> MicrophoneCaptureSPSCRing.EnqueueResult {
        ring.enqueue(samples, sampleTime: sampleTime)
    }

    /// Control-thread fence. Removing the tap happens before this call, so all
    /// frames accepted by that tap generation are delivered before it returns.
    @discardableResult
    func closeAndWait() -> MicrophoneCaptureTerminalReason? {
        ring.close()
        if started.load(ordering: .acquiring) {
            completion.wait()
            thread = nil
        }
        return ring.didOverflow ? .overflow : nil
    }

    private func run() {
        while true {
            var consumedFrame = false
            while ring.consume({ [self] samples, sampleTime in
                consumedFrame = true
                let output = resampler.process(samples)
                guard output.isEmpty == false else { return }
                let data = output.withUnsafeBufferPointer { Data(buffer: $0) }
                let timestampNs = Self.timestampNanoseconds(
                    sampleTime: sampleTime,
                    sampleRate: inputSampleRate
                )
                onAudio(generation, data, timestampNs)
            }) {}

            if ring.claimOverflowNotification() {
                onOverflow(generation)
            }
            if ring.isClosedAndDrained {
                // The producer-in-flight fence above guarantees no later
                // publication can appear after this final notification check.
                if ring.claimOverflowNotification() {
                    onOverflow(generation)
                }
                return
            }
            if consumedFrame == false {
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
    }

    private static func timestampNanoseconds(sampleTime: Int64, sampleRate: Double) -> UInt64 {
        guard sampleTime > 0, sampleRate > 0 else { return 0 }
        let value = Double(sampleTime) * 1_000_000_000 / sampleRate
        guard value < Double(UInt64.max) else { return UInt64.max }
        return UInt64(value)
    }
}

/// Process-wide single microphone owner. Only one subscription and one
/// AVAudioEngine tap may exist. The tap publishes fixed-size Float32 blocks to
/// a preallocated SPSC ring; a generation-scoped worker owns all DSP and
/// callback work.
final class MicrophoneCapture {
    static let shared = MicrophoneCapture()

    struct SubscriptionToken: Hashable {
        fileprivate let id: UUID
    }

    private struct ActiveSubscription {
        let token: SubscriptionToken
        let worker: MicrophoneCaptureWorker
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xyz.voice.zulangue",
        category: "MicrophoneCapture"
    )
    private static let targetSampleRate: Double = 16_000
    private static let tapBufferFrames: AVAudioFrameCount = 4_800
    private static let ringCapacity = 8
    private static let maximumFramesPerSlot = 8_192

    private let engine = AVAudioEngine()
    /// Used only by lifecycle callers. The tap and worker never acquire it.
    private let lifecycleLock = NSLock()
    private var didPrewarm = false
    private var isEngineRunning = false
    private var nextGeneration: UInt64 = 0
    private var activeSubscription: ActiveSubscription?

    private init() {}

    func prewarm() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard didPrewarm == false else { return }
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
        didPrewarm = true
        Self.logger.info("MicrophoneCapture prewarm: audio graph prepared")
    }

    /// Starts the one process-wide microphone subscription. Overflow is
    /// delivered exactly once from the worker after all earlier accepted slots
    /// have been handed to `callback`.
    func subscribe(
        onOverflow: @escaping @Sendable () -> Void,
        _ callback: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> SubscriptionToken {
        lifecycleLock.lock()
        guard activeSubscription == nil, isEngineRunning == false else {
            lifecycleLock.unlock()
            throw CaptureError.alreadySubscribed
        }

        let startedAt = Date()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let inputSampleRate = inputFormat.sampleRate
        guard inputSampleRate > 0,
              inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32
        else {
            lifecycleLock.unlock()
            throw CaptureError.formatError
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        let token = SubscriptionToken(id: UUID())
        let worker = MicrophoneCaptureWorker(
            generation: generation,
            inputSampleRate: inputSampleRate,
            ringCapacity: Self.ringCapacity,
            maximumFramesPerSlot: Self.maximumFramesPerSlot,
            onAudio: { workerGeneration, data, timestampNs in
                guard workerGeneration == generation else { return }
                callback(data, timestampNs)
            },
            onOverflow: { workerGeneration in
                guard workerGeneration == generation else { return }
                onOverflow()
            }
        )
        worker.start()
        activeSubscription = ActiveSubscription(token: token, worker: worker)

        Self.logger.info(
            "startEngine: input \(inputSampleRate)Hz \(inputFormat.channelCount)ch; worker generation \(generation)"
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferFrames,
            format: inputFormat
        ) { [worker] buffer, time in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            let input = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            worker.enqueue(input, sampleTime: time.sampleTime)
        }

        if didPrewarm == false {
            engine.prepare()
            didPrewarm = true
        }
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            activeSubscription = nil
            worker.closeAndWait()
            lifecycleLock.unlock()
            throw error
        }
        isEngineRunning = true
        lifecycleLock.unlock()

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
        Self.logger.info(
            "startEngine: generation \(generation) started in \(elapsed)ms; resampling to \(Self.targetSampleRate)Hz"
        )
        return token
    }

    /// Idempotent control-thread fence. No worker callback from this generation
    /// can run after the method returns, so a later subscription cannot receive
    /// stale audio or overflow state.
    @discardableResult
    func unsubscribe(_ token: SubscriptionToken) -> MicrophoneCaptureTerminalReason? {
        lifecycleLock.lock()
        guard let active = activeSubscription, active.token == token else {
            lifecycleLock.unlock()
            return nil
        }

        if isEngineRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isEngineRunning = false
        }
        let terminalReason = active.worker.closeAndWait()
        activeSubscription = nil
        lifecycleLock.unlock()
        Self.logger.info("stopEngine: generation \(active.worker.generation) drained and stopped")
        return terminalReason
    }
}

enum CaptureError: Error {
    case formatError
    case converterError
    case permissionDenied
    case alreadySubscribed
}
