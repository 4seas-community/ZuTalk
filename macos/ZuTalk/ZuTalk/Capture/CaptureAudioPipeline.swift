import AVFoundation
import Combine
import Foundation

// MARK: - Single microphone seam

struct NotebookCaptureAudioToken: Hashable {
    let id: UUID
}

/// Bounded single-consumer queue between the AVAudioEngine tap and Rust.
/// `submit` only performs atomic operations plus a bounded async enqueue; it
/// never waits for a lock or semaphore. Pause/stop atomically close admission,
/// then asynchronously fence all frames accepted before that transition.
final class NotebookCaptureAudioPushGate: @unchecked Sendable {
    enum SubmissionResult: Equatable, Sendable {
        case accepted
        case closed
        case overflow
    }

    private enum State: Int, Sendable {
        case accepting = 0
        case closed = 1
        case overflow = 2
        case pushFailure = 3
        case aborted = 4
    }

    private let queue = DispatchQueue(label: "app.zutalk.notebook-capture-audio")
    private let push: @Sendable (Data) -> String?
    private let onTerminal: @Sendable (String) -> Void
    private let capacity: Int
    private let state = CaptureAtomicInt(State.accepting.rawValue)
    private let pendingCount = CaptureAtomicInt(0)
    private let fenceLock = NSLock()
    nonisolated(unsafe) private var fenceWaiters: [CheckedContinuation<Void, Never>] = []
    private let failureLock = NSLock()
    nonisolated(unsafe) private var pushFailureMessage: String?

    nonisolated init(
        capacity: Int = 8,
        push: @escaping @Sendable (Data) -> String?,
        onTerminal: @escaping @Sendable (String) -> Void
    ) {
        self.capacity = max(1, capacity)
        self.push = push
        self.onTerminal = onTerminal
    }

    /// Called directly by the AVAudioEngine tap. At most `capacity` accepted
    /// blocks can be queued or in-flight, so Dispatch work allocation is also
    /// bounded when Rust persistence slows down.
    @discardableResult
    nonisolated func submit(_ audioData: Data) -> SubmissionResult {
        guard audioData.isEmpty == false else { return .closed }

        while true {
            let currentState = state.loadAcquire()
            guard currentState == State.accepting.rawValue else {
                return currentState == State.closed.rawValue ? .closed : .overflow
            }

            let currentPending = pendingCount.loadRelaxed()
            if currentPending >= capacity {
                let transitioned = state.compareExchangeAcquiringAndReleasing(
                    expected: State.accepting.rawValue,
                    desired: State.overflow.rawValue
                )
                if transitioned {
                    onTerminal(NotebookCaptureInterruptReason.localAudioOverflow.rawValue)
                    return .overflow
                }
                continue
            }

            let reserved = pendingCount.compareExchangeAcquiringAndReleasing(
                expected: currentPending,
                desired: currentPending + 1
            )
            guard reserved else { continue }

            // Close may race between the first state load and reservation.
            // Frames reserved after close are rejected; frames whose second
            // check wins are accepted and therefore covered by `fence()`.
            let reservedState = state.loadAcquire()
            guard reservedState == State.accepting.rawValue else {
                rejectReservationFromTap()
                return reservedState == State.closed.rawValue ? .closed : .overflow
            }

            queue.async { [self] in pushAcceptedFrame(audioData) }
            return .accepted
        }
    }

    nonisolated func close() {
        _ = state.compareExchangeAcquiringAndReleasing(
            expected: State.accepting.rawValue,
            desired: State.closed.rawValue
        )
    }

    @discardableResult
    nonisolated func reopen() -> Bool {
        guard pendingCount.loadAcquire() == 0 else { return false }
        return state.compareExchangeAcquiringAndReleasing(
            expected: State.closed.rawValue,
            desired: State.accepting.rawValue
        )
    }

    nonisolated func abort() {
        state.storeRelease(State.aborted.rawValue)
        resumeFenceWaitersIfDrained()
    }

    nonisolated func fence() async {
        await withCheckedContinuation { continuation in
            fenceLock.lock()
            if pendingCount.loadAcquire() == 0 {
                fenceLock.unlock()
                continuation.resume()
            } else {
                fenceWaiters.append(continuation)
                fenceLock.unlock()
            }
        }
    }

    nonisolated var pendingCountForTesting: Int {
        pendingCount.loadAcquire()
    }

    /// Available after `fence()` for deterministic pause/stop decisions. A
    /// persistence failure upgrades an earlier overflow because Rust has
    /// already durably interrupted the run in that case.
    nonisolated var terminalMessage: String? {
        switch state.loadAcquire() {
        case State.overflow.rawValue:
            return NotebookCaptureInterruptReason.localAudioOverflow.rawValue
        case State.pushFailure.rawValue:
            failureLock.lock()
            defer { failureLock.unlock() }
            return pushFailureMessage
        default:
            return nil
        }
    }

    private nonisolated func pushAcceptedFrame(_ audioData: Data) {
        let currentState = state.loadAcquire()
        guard currentState != State.aborted.rawValue,
              currentState != State.pushFailure.rawValue
        else {
            finishAcceptedFrame()
            return
        }

        if let message = push(audioData) {
            failureLock.lock()
            pushFailureMessage = message
            failureLock.unlock()

            while true {
                let observed = state.loadAcquire()
                guard observed != State.aborted.rawValue,
                      observed != State.pushFailure.rawValue
                else { break }
                if state.compareExchangeAcquiringAndReleasing(
                    expected: observed,
                    desired: State.pushFailure.rawValue
                ) {
                    onTerminal(message)
                    break
                }
            }
        }
        finishAcceptedFrame()
    }

    private nonisolated func finishAcceptedFrame() {
        let previous = pendingCount.fetchAddAcquiringAndReleasing(-1)
        precondition(previous > 0, "audio gate pending count underflow")
        if previous == 1 {
            resumeFenceWaitersIfDrained()
        }
    }

    /// Reservation rollback can run on the AVAudioEngine tap. Any waiter
    /// bookkeeping is deferred to the bounded serial queue so the tap never
    /// acquires `fenceLock`.
    private nonisolated func rejectReservationFromTap() {
        let previous = pendingCount.fetchAddAcquiringAndReleasing(-1)
        precondition(previous > 0, "audio gate pending count underflow")
        if previous == 1 {
            queue.async { [self] in resumeFenceWaitersIfDrained() }
        }
    }

    private nonisolated func resumeFenceWaitersIfDrained() {
        guard pendingCount.loadAcquire() == 0 else { return }
        fenceLock.lock()
        guard pendingCount.loadAcquire() == 0 else {
            fenceLock.unlock()
            return
        }
        let waiters = fenceWaiters
        fenceWaiters.removeAll(keepingCapacity: true)
        fenceLock.unlock()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
protocol NotebookCaptureAudioSourcing: AnyObject {
    var selectedInputDeviceUID: String? { get }
    var preparedInputDevice: AudioInputDevice? { get }

    func prepare() async throws
    func resolveInputDevice(uid: String?) throws -> AudioInputDevice
    func commitInputDeviceSelection(uid: String?, device: AudioInputDevice)
    func subscribe(
        inputDevice: AudioInputDevice,
        onAudio: @escaping @Sendable (Data) -> Void,
        onOverflow: @escaping @Sendable () -> Void
    ) throws -> NotebookCaptureAudioToken
    @discardableResult
    func unsubscribe(_ token: NotebookCaptureAudioToken) -> NotebookCaptureInterruptReason?
}

@MainActor
final class LiveNotebookCaptureAudioSource: NotebookCaptureAudioSourcing {
    private var subscriptions: [NotebookCaptureAudioToken: MicrophoneCapture.SubscriptionToken] = [:]
    private let inputDevices: AudioInputDeviceStore
    private(set) var preparedInputDevice: AudioInputDevice?

    init(inputDevices: AudioInputDeviceStore? = nil) {
        self.inputDevices = inputDevices ?? .shared
    }

    var selectedInputDeviceUID: String? { inputDevices.selectedUID }

    func prepare() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            if !granted { throw RecordingLiveError.microphonePermissionDenied }
        case .denied, .restricted:
            throw RecordingLiveError.microphonePermissionDenied
        @unknown default:
            throw RecordingLiveError.microphonePermissionDenied
        }
        preparedInputDevice = try inputDevices.resolveDeviceForCapture()
    }

    func resolveInputDevice(uid: String?) throws -> AudioInputDevice {
        try inputDevices.resolveDevice(uid: uid)
    }

    func commitInputDeviceSelection(uid: String?, device: AudioInputDevice) {
        inputDevices.select(uid: uid)
        preparedInputDevice = device
    }

    func subscribe(
        inputDevice: AudioInputDevice,
        onAudio: @escaping @Sendable (Data) -> Void,
        onOverflow: @escaping @Sendable () -> Void
    ) throws -> NotebookCaptureAudioToken {
        let sourceToken = try MicrophoneCapture.shared.subscribe(
            inputDevice: inputDevice,
            onOverflow: onOverflow,
            { data, _ in onAudio(data) }
        )
        let token = NotebookCaptureAudioToken(id: UUID())
        subscriptions[token] = sourceToken
        return token
    }

    @discardableResult
    func unsubscribe(_ token: NotebookCaptureAudioToken) -> NotebookCaptureInterruptReason? {
        guard let sourceToken = subscriptions.removeValue(forKey: token) else { return nil }
        switch MicrophoneCapture.shared.unsubscribe(sourceToken) {
        case .overflow:
            return .localAudioOverflow
        case nil:
            return nil
        }
    }
}

