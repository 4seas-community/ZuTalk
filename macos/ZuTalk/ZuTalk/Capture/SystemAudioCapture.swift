import AudioToolbox
import CoreAudio
import Foundation
import os

// MARK: - System audio input

extension AudioInputDevice {
    /// Not a CoreAudio device but what the Mac plays: the far side of an
    /// online meeting, a video, a call. It sits in the same picker as the
    /// microphones so pause, resume and mid-capture switching keep working
    /// unchanged; only the audio source routes it to `SystemAudioCapture`.
    static let systemAudioUID = "zutalk.system-audio"

    static var systemAudio: AudioInputDevice {
        AudioInputDevice(
            deviceID: AudioDeviceID(kAudioObjectUnknown),
            uid: systemAudioUID,
            name: String(localized: "settings.audio_input.system_audio")
        )
    }

    var isSystemAudio: Bool { uid == Self.systemAudioUID }
}

/// Gathers the tap's short IO buffers (typically 512 frames) into blocks of
/// about 100 ms — the cadence the microphone tap delivers, and the one the
/// SPSC ring and the push gate in front of Rust are sized for. Delivering
/// every IO buffer would push ten times as many blocks through a gate that
/// admits eight at a time.
///
/// Producer-only: called from the one serial IO queue, never allocates.
final class SystemAudioChunker: @unchecked Sendable {
    let chunkFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private var filled = 0
    private var chunkStartSampleTime: Int64 = 0

    init(chunkFrames: Int) {
        precondition(chunkFrames > 0)
        self.chunkFrames = chunkFrames
        storage = .allocate(capacity: chunkFrames)
        storage.initialize(repeating: 0, count: chunkFrames)
    }

    deinit {
        storage.deinitialize(count: chunkFrames)
        storage.deallocate()
    }

    /// Copies one channel of `samples` (interleaved with `stride`) and calls
    /// `emit` with every full block. A jump in `sampleTime` closes the partial
    /// block first so each block's start time stays exact.
    func append(
        _ samples: UnsafePointer<Float>,
        frameCount: Int,
        stride: Int,
        sampleTime: Int64,
        emit: (UnsafePointer<Float>, Int, Int64) -> Void
    ) {
        guard frameCount > 0, stride > 0 else { return }
        if filled > 0, sampleTime != chunkStartSampleTime + Int64(filled) {
            flush(emit: emit)
        }
        var consumed = 0
        while consumed < frameCount {
            if filled == 0 {
                chunkStartSampleTime = sampleTime + Int64(consumed)
            }
            let count = min(chunkFrames - filled, frameCount - consumed)
            let destination = storage.advanced(by: filled)
            if stride == 1 {
                destination.update(from: samples.advanced(by: consumed), count: count)
            } else {
                for frame in 0..<count {
                    destination[frame] = samples[(consumed + frame) * stride]
                }
            }
            filled += count
            consumed += count
            if filled == chunkFrames {
                emit(storage, filled, chunkStartSampleTime)
                filled = 0
            }
        }
    }

    func flush(emit: (UnsafePointer<Float>, Int, Int64) -> Void) {
        guard filled > 0 else { return }
        emit(storage, filled, chunkStartSampleTime)
        filled = 0
    }
}

/// Process-wide owner of the one system-audio subscription. A Core Audio
/// process tap mixes everything the Mac plays (except ZuTalk itself) down to
/// one channel; a private aggregate device carries the tap so an IO proc can
/// read it. Frames then go through the same ring, worker and 16 kHz resampler
/// as the microphone, so nothing downstream knows which source it came from.
///
/// Requires macOS 14.2. The first start asks for the system's "System Audio
/// Recording" permission; if it is refused, Core Audio delivers silence
/// rather than an error.
final class SystemAudioCapture {
    static let shared = SystemAudioCapture()

    struct SubscriptionToken: Hashable {
        fileprivate let id: UUID
    }

    private struct ActiveSubscription {
        let token: SubscriptionToken
        let worker: MicrophoneCaptureWorker
        let chunker: SystemAudioChunker
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xyz.voice.zutalk",
        category: "SystemAudioCapture"
    )
    private static let chunkDuration: Double = 0.1
    private static let ringCapacity = 32
    private static let minimumFramesPerSlot = 8_192
    private static let maximumDroppedDuration: Double = 15

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private let ioQueue = DispatchQueue(
        label: "app.zutalk.system-audio-io",
        qos: .userInteractive
    )
    /// Used only by lifecycle callers. The IO block never acquires it.
    private let lifecycleLock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeSubscription: ActiveSubscription?

    private init() {}

    func subscribe(
        onOverflow: @escaping @Sendable () -> Void,
        _ callback: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> SubscriptionToken {
        guard #available(macOS 14.2, *) else {
            throw AudioInputDeviceError.systemAudioUnsupported
        }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard activeSubscription == nil else {
            throw CaptureError.alreadySubscribed
        }

        let startedAt = Date()
        let tapID = try Self.createTap()
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        do {
            aggregateID = try Self.createAggregateDevice(tapID: tapID)
            let sampleRate = try Self.sampleRate(aggregateID: aggregateID, tapID: tapID)

            nextGeneration &+= 1
            let generation = nextGeneration
            let chunkFrames = max(1, Int((sampleRate * Self.chunkDuration).rounded(.up)))
            let chunker = SystemAudioChunker(chunkFrames: chunkFrames)
            let worker = MicrophoneCaptureWorker(
                generation: generation,
                inputSampleRate: sampleRate,
                ringCapacity: Self.ringCapacity,
                maximumFramesPerSlot: max(Self.minimumFramesPerSlot, chunkFrames),
                maximumDroppedFrames: Int(sampleRate * Self.maximumDroppedDuration),
                onAudio: { workerGeneration, data, timestampNs in
                    guard workerGeneration == generation else { return }
                    callback(data, timestampNs)
                },
                onOverflow: { workerGeneration in
                    guard workerGeneration == generation else { return }
                    onOverflow()
                }
            )

            var ioProcID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateID,
                ioQueue
            ) { [worker, chunker] _, inputData, inputTime, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inputData)
                )
                guard let buffer = buffers.first,
                      let data = buffer.mData,
                      buffer.mNumberChannels > 0
                else { return }
                let stride = Int(buffer.mNumberChannels)
                let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
                guard frameCount > 0 else { return }
                let sampleTime = inputTime.pointee.mFlags.contains(.sampleTimeValid)
                    ? Int64(max(0, inputTime.pointee.mSampleTime))
                    : 0
                chunker.append(
                    data.assumingMemoryBound(to: Float.self),
                    frameCount: frameCount,
                    stride: stride,
                    sampleTime: sampleTime
                ) { block, count, blockSampleTime in
                    worker.enqueue(
                        block,
                        frameCount: count,
                        stride: 1,
                        sampleTime: blockSampleTime
                    )
                }
            }
            guard createStatus == noErr, let ioProcID else {
                throw AudioInputDeviceError.systemAudioFailed(
                    operation: "io proc",
                    status: createStatus
                )
            }

            worker.start()
            let startStatus = AudioDeviceStart(aggregateID, ioProcID)
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                ioQueue.sync {}
                worker.closeAndWait()
                throw AudioInputDeviceError.systemAudioFailed(
                    operation: "start",
                    status: startStatus
                )
            }

            let token = SubscriptionToken(id: UUID())
            activeSubscription = ActiveSubscription(
                token: token,
                worker: worker,
                chunker: chunker,
                tapID: tapID,
                aggregateID: aggregateID,
                ioProcID: ioProcID
            )
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Self.logger.info(
                "system audio generation \(generation) started at \(sampleRate)Hz in \(elapsed)ms"
            )
            return token
        } catch {
            if aggregateID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    /// Idempotent control-thread fence, like `MicrophoneCapture.unsubscribe`:
    /// no callback from this generation runs after it returns, and the last
    /// partial block is delivered before the worker drains.
    @discardableResult
    func unsubscribe(_ token: SubscriptionToken) -> MicrophoneCaptureTerminalReason? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let active = activeSubscription, active.token == token else { return nil }

        AudioDeviceStop(active.aggregateID, active.ioProcID)
        AudioDeviceDestroyIOProcID(active.aggregateID, active.ioProcID)
        // IO blocks already queued before the stop still run; this waits for
        // them, then hands over what the chunker holds.
        ioQueue.sync {
            active.chunker.flush { block, count, blockSampleTime in
                active.worker.enqueue(
                    block,
                    frameCount: count,
                    stride: 1,
                    sampleTime: blockSampleTime
                )
            }
        }
        let terminalReason = active.worker.closeAndWait()
        if #available(macOS 14.2, *) {
            AudioHardwareDestroyAggregateDevice(active.aggregateID)
            AudioHardwareDestroyProcessTap(active.tapID)
        }
        activeSubscription = nil
        Self.logger.info("system audio generation \(active.worker.generation) drained and stopped")
        return terminalReason
    }

    // MARK: Core Audio plumbing

    @available(macOS 14.2, *)
    private static func createTap() throws -> AudioObjectID {
        // Leave ZuTalk's own output out of the mix, so nothing it plays can be
        // transcribed back into the recording.
        let excluded = ownProcessObjectID().map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "ZuTalk System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw AudioInputDeviceError.systemAudioFailed(operation: "tap", status: status)
        }
        return tapID
    }

    @available(macOS 14.2, *)
    private static func createAggregateDevice(tapID: AudioObjectID) throws -> AudioObjectID {
        let tapUID = try readString(tapID, selector: kAudioTapPropertyUID, operation: "tap uid")
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ZuTalk System Audio",
            kAudioAggregateDeviceUIDKey: "app.zutalk.system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        // The output device gives the aggregate its clock. Without one (no
        // speakers attached) the tap alone still runs.
        if let outputUID = defaultOutputDeviceUID() {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outputUID],
            ]
        }

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw AudioInputDeviceError.systemAudioFailed(operation: "aggregate", status: status)
        }
        return aggregateID
    }

    /// The rate the IO proc actually delivers frames at is the aggregate's;
    /// the tap's own format is the fallback when the aggregate cannot say.
    @available(macOS 14.2, *)
    private static func sampleRate(aggregateID: AudioObjectID, tapID: AudioObjectID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nominal: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &nominal) == noErr,
           nominal.isFinite, nominal > 0 {
            return nominal
        }

        address.mSelector = kAudioTapPropertyFormat
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate.isFinite, format.mSampleRate > 0 else {
            throw AudioInputDeviceError.systemAudioFailed(operation: "format", status: status)
        }
        return format.mSampleRate
    }

    private static func ownProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return try? readString(deviceID, selector: kAudioDevicePropertyDeviceUID, operation: "output uid")
    }

    private static func readString(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else {
            throw AudioInputDeviceError.systemAudioFailed(operation: operation, status: status)
        }
        return value.takeRetainedValue() as String
    }
}
