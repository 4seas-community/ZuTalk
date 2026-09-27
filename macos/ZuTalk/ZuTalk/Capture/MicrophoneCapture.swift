import AVFoundation
import AudioToolbox
import Darwin
import Foundation
import os

/// Lock-free capture atomics for the macOS 12.5 runtime floor.
///
/// `Synchronization.Atomic` is only available on newer macOS releases. These
/// legacy OSAtomic entry points have existed since macOS 10.4 and map to native
/// atomic read/modify/write instructions. Barrier variants are stronger than
/// the acquire/release operations required by the capture queues. Storage is
/// allocated once and naturally aligned before any realtime callback runs.
final class CaptureAtomicInt: @unchecked Sendable {
    nonisolated(unsafe) private let storage: UnsafeMutablePointer<Int64>

    nonisolated init(_ initialValue: Int) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: Int64(initialValue))
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    @inline(__always)
    nonisolated func loadRelaxed() -> Int {
        Int(OSAtomicAdd64(0, storage))
    }

    @inline(__always)
    nonisolated func loadAcquire() -> Int {
        Int(OSAtomicAdd64Barrier(0, storage))
    }

    @inline(__always)
    nonisolated func storeRelease(_ desired: Int) {
        let desired = Int64(desired)
        var observed = OSAtomicAdd64(0, storage)
        while OSAtomicCompareAndSwap64Barrier(observed, desired, storage) == false {
            observed = OSAtomicAdd64(0, storage)
        }
    }

    @inline(__always)
    nonisolated func compareExchangeAcquiringAndReleasing(
        expected: Int,
        desired: Int
    ) -> Bool {
        OSAtomicCompareAndSwap64Barrier(Int64(expected), Int64(desired), storage)
    }

    /// Returns the value before addition, matching an atomic fetch-add.
    @inline(__always)
    nonisolated func fetchAddAcquiringAndReleasing(_ operand: Int) -> Int {
        let operand = Int64(operand)
        let updated = OSAtomicAdd64Barrier(operand, storage)
        return Int(updated &- operand)
    }
}

final class CaptureAtomicBool: @unchecked Sendable {
    private let storage: CaptureAtomicInt

    nonisolated init(_ initialValue: Bool) {
        storage = CaptureAtomicInt(initialValue ? 1 : 0)
    }

    @inline(__always)
    nonisolated func loadAcquire() -> Bool {
        storage.loadAcquire() != 0
    }

    @inline(__always)
    nonisolated func storeRelease(_ desired: Bool) {
        storage.storeRelease(desired ? 1 : 0)
    }

    @inline(__always)
    nonisolated func compareExchangeAcquiringAndReleasing(
        expected: Bool,
        desired: Bool
    ) -> Bool {
        storage.compareExchangeAcquiringAndReleasing(
            expected: expected ? 1 : 0,
            desired: desired ? 1 : 0
        )
    }
}

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
/// copy into memory allocated before the tap is installed.
///
/// A full ring drops the incoming buffer and counts it, rather than ending the
/// recording. The count travels with the next buffer that does fit, so the
/// worker can put back exactly that much silence in exactly that place and
/// every later frame keeps its position on the recording's timeline.
///
/// Ending the recording was the old policy, and with eight 100 ms slots it
/// meant any 800 ms stall of the worker thread threw away the rest of a
/// meeting: fifteen of thirty-four recordings longer than ten minutes on one
/// machine ended as `local_audio_overflow`, most of them between the 21st and
/// the 26th minute, in the tail of pushes that were themselves fast. A short
/// silent hole costs a sentence; the old outcome cost everything after it.
/// Only a stall longer than `maximumDroppedFrames` is still treated as the
/// capture being broken.
final class MicrophoneCaptureSPSCRing: @unchecked Sendable {
    enum EnqueueResult: Equatable, Sendable {
        case accepted
        /// The ring was full (or the buffer larger than a slot). The frames
        /// are counted and will be restored as silence before the next
        /// accepted buffer.
        case dropped
        case closed
        case overflow
    }

    let capacity: Int
    let maximumFramesPerSlot: Int
    /// Consecutive dropped frames tolerated before the ring gives up.
    let maximumDroppedFrames: Int

    private let sampleStorage: UnsafeMutablePointer<Float>
    private let frameCounts: UnsafeMutablePointer<Int>
    private let sampleTimes: UnsafeMutablePointer<Int64>
    /// Frames dropped immediately before each slot's buffer.
    private let droppedBefore: UnsafeMutablePointer<Int>
    /// Producer-only: frames dropped since the last accepted buffer.
    nonisolated(unsafe) private var pendingDroppedFrames = 0
    private let writeSequence = CaptureAtomicInt(0)
    private let readSequence = CaptureAtomicInt(0)
    private let producerInFlight = CaptureAtomicInt(0)
    private let accepting = CaptureAtomicBool(true)
    private let overflowNotificationPending = CaptureAtomicBool(false)
    private let overflowDetected = CaptureAtomicBool(false)

    init(capacity: Int, maximumFramesPerSlot: Int, maximumDroppedFrames: Int = 0) {
        precondition(capacity > 0)
        precondition(maximumFramesPerSlot > 0)
        precondition(maximumDroppedFrames >= 0)
        self.capacity = capacity
        self.maximumFramesPerSlot = maximumFramesPerSlot
        self.maximumDroppedFrames = maximumDroppedFrames
        sampleStorage = .allocate(capacity: capacity * maximumFramesPerSlot)
        frameCounts = .allocate(capacity: capacity)
        sampleTimes = .allocate(capacity: capacity)
        droppedBefore = .allocate(capacity: capacity)
        sampleStorage.initialize(repeating: 0, count: capacity * maximumFramesPerSlot)
        frameCounts.initialize(repeating: 0, count: capacity)
        sampleTimes.initialize(repeating: 0, count: capacity)
        droppedBefore.initialize(repeating: 0, count: capacity)
    }

    deinit {
        sampleStorage.deinitialize(count: capacity * maximumFramesPerSlot)
        frameCounts.deinitialize(count: capacity)
        sampleTimes.deinitialize(count: capacity)
        droppedBefore.deinitialize(count: capacity)
        sampleStorage.deallocate()
        frameCounts.deallocate()
        sampleTimes.deallocate()
        droppedBefore.deallocate()
    }

    /// Realtime producer entrypoint. There is exactly one AVAudioEngine tap.
    @discardableResult
    func enqueue(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64) -> EnqueueResult {
        guard let baseAddress = samples.baseAddress else { return .closed }
        return enqueue(
            baseAddress,
            frameCount: samples.count,
            stride: 1,
            sampleTime: sampleTime
        )
    }

    /// Copies one channel from either planar (`stride == 1`) or interleaved
    /// hardware input without allocating on the realtime audio thread.
    @discardableResult
    func enqueue(
        _ samples: UnsafePointer<Float>,
        frameCount: Int,
        stride: Int,
        sampleTime: Int64
    ) -> EnqueueResult {
        _ = producerInFlight.fetchAddAcquiringAndReleasing(1)
        defer {
            let previous = producerInFlight.fetchAddAcquiringAndReleasing(-1)
            precondition(previous > 0, "microphone ring producer count underflow")
        }

        guard accepting.loadAcquire() else { return .closed }
        guard frameCount > 0, stride > 0 else { return .closed }

        let write = writeSequence.loadRelaxed()
        let read = readSequence.loadAcquire()
        guard frameCount <= maximumFramesPerSlot, write - read < capacity else {
            return drop(frameCount)
        }

        let slot = write % capacity
        let destination = sampleStorage.advanced(by: slot * maximumFramesPerSlot)
        if stride == 1 {
            destination.update(from: samples, count: frameCount)
        } else {
            for frame in 0..<frameCount {
                destination[frame] = samples[frame * stride]
            }
        }
        frameCounts[slot] = frameCount
        sampleTimes[slot] = sampleTime
        droppedBefore[slot] = pendingDroppedFrames
        pendingDroppedFrames = 0
        writeSequence.storeRelease(write + 1)
        return .accepted
    }

    /// Producer-only. Counts a buffer that did not fit; gives up only once
    /// the worker has been gone long enough that silence would be a lie
    /// about a capture that is no longer running.
    private func drop(_ frameCount: Int) -> EnqueueResult {
        pendingDroppedFrames += frameCount
        guard pendingDroppedFrames <= maximumDroppedFrames else {
            return closeForOverflow()
        }
        return .dropped
    }

    /// Single-worker consumer entrypoint. The slot is not released back to the
    /// tap until `body` returns, so the provided pointer remains stable.
    @discardableResult
    func consume(
        _ body: (UnsafeBufferPointer<Float>, Int64) -> Void
    ) -> Bool {
        consumeWithDroppedFrames { samples, sampleTime, _ in body(samples, sampleTime) }
    }

    /// Like `consume`, also passing how many frames were dropped immediately
    /// before this buffer.
    @discardableResult
    func consumeWithDroppedFrames(
        _ body: (UnsafeBufferPointer<Float>, Int64, Int) -> Void
    ) -> Bool {
        let read = readSequence.loadRelaxed()
        let write = writeSequence.loadAcquire()
        guard read < write else { return false }

        let slot = read % capacity
        let count = frameCounts[slot]
        let samples = UnsafeBufferPointer(
            start: sampleStorage.advanced(by: slot * maximumFramesPerSlot),
            count: count
        )
        body(samples, sampleTimes[slot], droppedBefore[slot])
        readSequence.storeRelease(read + 1)
        return true
    }

    func close() {
        accepting.storeRelease(false)
    }

    /// Claimed by the worker, never by the realtime producer. The compare and
    /// exchange makes the overflow callback exactly-once.
    func claimOverflowNotification() -> Bool {
        overflowNotificationPending.compareExchangeAcquiringAndReleasing(
            expected: true,
            desired: false
        )
    }

    var isClosedAndDrained: Bool {
        guard accepting.loadAcquire() == false,
              producerInFlight.loadAcquire() == 0
        else { return false }
        return readSequence.loadAcquire() == writeSequence.loadAcquire()
    }

    var pendingCountForTesting: Int {
        writeSequence.loadAcquire() - readSequence.loadAcquire()
    }

    var didOverflow: Bool {
        overflowDetected.loadAcquire()
    }

    private func closeForOverflow() -> EnqueueResult {
        let transitioned = accepting.compareExchangeAcquiringAndReleasing(
            expected: true,
            desired: false
        )
        guard transitioned else { return .closed }
        overflowDetected.storeRelease(true)
        overflowNotificationPending.storeRelease(true)
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
    private let started = CaptureAtomicBool(false)
    private let completion = DispatchGroup()
    private var thread: Thread?

    /// Zeros restored in place of dropped frames, at most one slot at a time.
    private let silence: [Float]
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xyz.voice.zutalk",
        category: "MicrophoneCapture"
    )

    init(
        generation: UInt64,
        inputSampleRate: Double,
        ringCapacity: Int,
        maximumFramesPerSlot: Int,
        maximumDroppedFrames: Int = 0,
        onAudio: @escaping @Sendable (UInt64, Data, UInt64) -> Void,
        onOverflow: @escaping @Sendable (UInt64) -> Void
    ) {
        precondition(inputSampleRate > 0)
        self.generation = generation
        self.inputSampleRate = inputSampleRate
        ring = MicrophoneCaptureSPSCRing(
            capacity: ringCapacity,
            maximumFramesPerSlot: maximumFramesPerSlot,
            maximumDroppedFrames: maximumDroppedFrames
        )
        resampler = StreamingS16Resampler(inputSampleRate: inputSampleRate)
        silence = Array(repeating: 0, count: maximumFramesPerSlot)
        self.onAudio = onAudio
        self.onOverflow = onOverflow
    }

    func start() {
        let transitioned = started.compareExchangeAcquiringAndReleasing(
            expected: false,
            desired: true
        )
        guard transitioned else { return }

        completion.enter()
        let thread = Thread { [self] in
            defer { completion.leave() }
            run()
        }
        thread.name = "ZuTalk microphone DSP \(generation)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Realtime producer entrypoint.
    @discardableResult
    func enqueue(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64) -> MicrophoneCaptureSPSCRing.EnqueueResult {
        ring.enqueue(samples, sampleTime: sampleTime)
    }

    @discardableResult
    func enqueue(
        _ samples: UnsafePointer<Float>,
        frameCount: Int,
        stride: Int,
        sampleTime: Int64
    ) -> MicrophoneCaptureSPSCRing.EnqueueResult {
        ring.enqueue(
            samples,
            frameCount: frameCount,
            stride: stride,
            sampleTime: sampleTime
        )
    }

    /// Control-thread fence. Removing the tap happens before this call, so all
    /// frames accepted by that tap generation are delivered before it returns.
    @discardableResult
    func closeAndWait() -> MicrophoneCaptureTerminalReason? {
        ring.close()
        if started.loadAcquire() {
            completion.wait()
            thread = nil
        }
        return ring.didOverflow ? .overflow : nil
    }

    private func run() {
        while true {
            var consumedFrame = false
            while ring.consumeWithDroppedFrames({ [self] samples, sampleTime, droppedFrames in
                consumedFrame = true
                if droppedFrames > 0 {
                    restoreDroppedFrames(droppedFrames, before: sampleTime)
                }
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

    /// Puts back, as silence, the frames the ring could not hold, so the
    /// buffer that follows lands at its true position on the timeline. Fed
    /// through the resampler like any other input: its phase and history
    /// carry on exactly as if the frames had been captured.
    private func restoreDroppedFrames(_ droppedFrames: Int, before sampleTime: Int64) {
        Self.logger.warning(
            "microphone worker fell behind; restoring \(droppedFrames) dropped frames as silence"
        )
        var remaining = droppedFrames
        while remaining > 0 {
            let count = min(remaining, silence.count)
            remaining -= count
            let output = silence.withUnsafeBufferPointer { zeros in
                resampler.process(UnsafeBufferPointer(rebasing: zeros[0..<count]))
            }
            guard output.isEmpty == false else { continue }
            let data = output.withUnsafeBufferPointer { Data(buffer: $0) }
            let restoredStart = sampleTime - Int64(remaining + count)
            onAudio(
                generation,
                data,
                Self.timestampNanoseconds(sampleTime: restoredStart, sampleRate: inputSampleRate)
            )
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
        subsystem: Bundle.main.bundleIdentifier ?? "xyz.voice.zutalk",
        category: "MicrophoneCapture"
    )
    private static let targetSampleRate: Double = 16_000
    private static let tapBufferDuration: Double = 0.1
    private static let maximumTapBufferDuration: Double = 0.4
    /// Three seconds of 100 ms tap buffers before the ring starts dropping.
    private static let ringCapacity = 32
    private static let minimumFramesPerSlot = 8_192
    /// How long the worker may stall before its silence would be covering for
    /// a capture that has stopped working. Sized so the restored silence plus
    /// a full ring stays inside the push gate's own backlog.
    private static let maximumDroppedDuration: Double = 15

    private var engine = AVAudioEngine()
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
        inputDevice: AudioInputDevice,
        onOverflow: @escaping @Sendable () -> Void,
        _ callback: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> SubscriptionToken {
        lifecycleLock.lock()
        guard activeSubscription == nil, isEngineRunning == false else {
            lifecycleLock.unlock()
            throw CaptureError.alreadySubscribed
        }

        let startedAt = Date()
        // AVAudioEngine keeps the old input node's format after a hardware
        // route changes. A fresh engine guarantees the selected device is
        // bound before any format is read or render resources are prepared.
        engine.stop()
        engine = AVAudioEngine()
        didPrewarm = false
        let inputNode = engine.inputNode
        do {
            try Self.bind(inputDevice, to: inputNode)
        } catch {
            lifecycleLock.unlock()
            throw error
        }
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let inputSampleRate = inputFormat.sampleRate
        guard inputSampleRate.isFinite,
              inputSampleRate > 0,
              inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32
        else {
            lifecycleLock.unlock()
            throw CaptureError.formatError
        }
        let tapBufferFrames = Self.tapBufferFrames(inputSampleRate: inputSampleRate)
        let maximumFramesPerSlot = Self.maximumFramesPerSlot(
            inputSampleRate: inputSampleRate
        )

        nextGeneration &+= 1
        let generation = nextGeneration
        let token = SubscriptionToken(id: UUID())
        let worker = MicrophoneCaptureWorker(
            generation: generation,
            inputSampleRate: inputSampleRate,
            ringCapacity: Self.ringCapacity,
            maximumFramesPerSlot: maximumFramesPerSlot,
            maximumDroppedFrames: Int(inputSampleRate * Self.maximumDroppedDuration),
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
            bufferSize: tapBufferFrames,
            format: inputFormat
        ) { [worker] buffer, time in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            worker.enqueue(
                channelData[0],
                frameCount: frameCount,
                stride: buffer.stride,
                sampleTime: time.sampleTime
            )
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

    private static func bind(
        _ inputDevice: AudioInputDevice,
        to inputNode: AVAudioInputNode
    ) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioInputDeviceError.audioUnitUnavailable(name: inputDevice.name)
        }

        var requestedDeviceID = inputDevice.deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &requestedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setStatus == noErr else {
            throw AudioInputDeviceError.bindingFailed(
                name: inputDevice.name,
                status: setStatus
            )
        }

        var actualDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        let getStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &actualDeviceID,
            &byteCount
        )
        guard getStatus == noErr, actualDeviceID == requestedDeviceID else {
            throw AudioInputDeviceError.bindingFailed(
                name: inputDevice.name,
                status: getStatus == noErr ? kAudioUnitErr_InvalidPropertyValue : getStatus
            )
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidValue: Unmanaged<CFString>?
        var uidByteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = AudioObjectGetPropertyData(
            actualDeviceID,
            &uidAddress,
            0,
            nil,
            &uidByteCount,
            &uidValue
        )
        guard uidStatus == noErr,
              let uidValue,
              uidValue.takeRetainedValue() as String == inputDevice.uid
        else {
            throw AudioInputDeviceError.bindingFailed(
                name: inputDevice.name,
                status: uidStatus == noErr ? kAudioUnitErr_InvalidPropertyValue : uidStatus
            )
        }
    }

    private static func tapBufferFrames(inputSampleRate: Double) -> AVAudioFrameCount {
        let frames = max(1, (inputSampleRate * tapBufferDuration).rounded(.up))
        return AVAudioFrameCount(min(frames, Double(AVAudioFrameCount.max)))
    }

    private static func maximumFramesPerSlot(inputSampleRate: Double) -> Int {
        max(
            minimumFramesPerSlot,
            Int((inputSampleRate * maximumTapBufferDuration).rounded(.up))
        )
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
