// SessionAudioPlayer.swift
// 录音回放
//
// 流程：
// 1. core.getAudioSegment(sessionId, 0, durationMs) → 解密后的 f32 PCM 字节
//    （sample_rate=16000, channels=1, bytes_per_sample=4, little-endian）
// 2. 包成 AVAudioPCMBuffer (pcmFormatFloat32, 16kHz, mono)
// 3. AVAudioEngine + AVAudioPlayerNode 播放
// 4. 用 playerNode.lastRenderTime + playerTime 算当前位置, 给 UI 显示
//
// 为什么不用 AVAudioPlayer:
//   AVAudioPlayer 只接受文件 URL 或 NSData (压缩格式), 不支持原始 PCM buffer.
//   AVAudioEngine 直接 schedule buffer 才是处理裸 PCM 的正确方式.
//
// 注意:
//   getAudioSegment 在 Rust 端是同步的, 这里在 background queue 调用避免阻塞 UI.

import AVFoundation
import Combine
import Foundation

@MainActor
final class SessionAudioPlayer: ObservableObject {
    /// 加载/播放状态
    enum State: Equatable {
        case idle               // 没数据
        case loading            // 正在解密获取 PCM
        case ready              // PCM 已加载, 可播放
        case playing
        case paused
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var positionMs: UInt64 = 0
    @Published private(set) var durationMs: UInt64 = 0
    @Published private(set) var sessionId: String? = nil

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioBuffer: AVAudioPCMBuffer?
    private var positionTimer: Timer?
    /// 播放开始时 playerNode 的 hostTime offset, 用来算 currentTime
    private var playStartFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0

    init() {
        engine.attach(playerNode)
    }

    deinit {
        positionTimer?.invalidate()
        engine.stop()
    }

    @MainActor
    private static func loadAudioSegment(
        using core: ZulangueCore,
        sessionId: String,
        endMs: UInt64
    ) throws -> Data {
        try core.getAudioSegment(sessionId: sessionId, startMs: 0, endMs: endMs)
    }

    /// 加载某个 session 的完整音频
    /// 已经在播放/加载中的 session 不会重复加载
    func load(session: SessionListItem) {
        // 同一 session 已就绪 → no-op
        if sessionId == session.id, audioBuffer != nil {
            return
        }
        // session 没有可用音频 (隐私销毁后) → 直接错误
        guard session.hasEncryptedAudio else {
            self.sessionId = session.id
            self.state = .error("Audio destroyed by privacy policy")
            return
        }
        guard session.durationMs > 0 else {
            self.sessionId = session.id
            self.state = .error("Empty recording")
            return
        }

        // 切换 session 时停下旧的
        stopInternal()

        self.sessionId = session.id
        self.durationMs = session.durationMs
        self.positionMs = 0
        self.state = .loading

        guard let core = CoreClient.shared.core else {
            self.state = .error("Core not initialized")
            return
        }

        let sid = session.id
        let dur = session.durationMs
        Task.detached(priority: .userInitiated) { [weak self, core, sid, dur] in
            do {
                // FFI 返回 f32 PCM 字节 (sample_rate=16000, channels=1)
                let pcmBytes = try await Self.loadAudioSegment(
                    using: core,
                    sessionId: sid,
                    endMs: dur
                )
                await MainActor.run { [weak self] in
                    self?.handleLoaded(pcmBytes: pcmBytes)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.state = .error("Decrypt failed: \(error)")
                }
            }
        }
    }

    /// 播放
    func play() {
        guard audioBuffer != nil else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            // 已经在播 → no-op
            if playerNode.isPlaying {
                return
            }
            scheduleAndPlay(fromFrame: pausedFrame)
            state = .playing
            startPositionTimer()
        } catch {
            state = .error("Engine start failed: \(error)")
        }
    }

    func pause() {
        guard playerNode.isPlaying else { return }
        // 记录当前帧, 下次 play 从这里继续
        pausedFrame = currentFrame()
        playerNode.pause()
        stopPositionTimer()
        state = .paused
    }

    func stop() {
        stopInternal()
        positionMs = 0
        if audioBuffer != nil {
            state = .ready
        }
    }

    /// Seek 到 ms 位置
    func seek(toMs targetMs: UInt64) {
        guard let buffer = audioBuffer else { return }
        let sampleRate = buffer.format.sampleRate
        let target = AVAudioFramePosition(Double(targetMs) / 1000.0 * sampleRate)
        let clamped = max(0, min(target, AVAudioFramePosition(buffer.frameLength)))

        let wasPlaying = playerNode.isPlaying
        playerNode.stop()
        pausedFrame = clamped
        positionMs = framesToMs(clamped, sampleRate: sampleRate)
        if wasPlaying {
            play()
        }
    }

    // MARK: - Internal

    private func handleLoaded(pcmBytes: Data) {
        // 16 kHz mono f32
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            state = .error("Format init failed")
            return
        }
        let frameCount = AVAudioFrameCount(pcmBytes.count / 4)
        guard frameCount > 0 else {
            state = .error("No audio frames")
            return
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            state = .error("Buffer alloc failed")
            return
        }
        buffer.frameLength = frameCount

        // 把 little-endian f32 字节 copy 到 AudioBufferList
        // pcmBytes 是 [f32 le, f32 le, ...], 直接 memcpy 到 channel buffer (host order)
        // macOS 是 little-endian, 直接 copy 即可
        pcmBytes.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.bindMemory(to: Float.self).baseAddress,
                  let dst = buffer.floatChannelData?[0] else {
                return
            }
            dst.update(from: src, count: Int(frameCount))
        }

        // 连接 player → main mixer
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        self.audioBuffer = buffer
        self.pausedFrame = 0
        self.positionMs = 0
        self.state = .ready
    }

    private func scheduleAndPlay(fromFrame startFrame: AVAudioFramePosition) {
        guard let buffer = audioBuffer else { return }
        let totalFrames = AVAudioFrameCount(buffer.frameLength)

        // 从 startFrame 起截一段(避免每次完整重传)
        if startFrame == 0 {
            playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handlePlaybackFinished()
                }
            }
        } else if startFrame < AVAudioFramePosition(totalFrames) {
            // 切片 buffer
            let segLen = totalFrames - AVAudioFrameCount(startFrame)
            guard let seg = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: segLen
            ) else { return }
            seg.frameLength = segLen
            if let src = buffer.floatChannelData?[0],
               let dst = seg.floatChannelData?[0] {
                dst.update(from: src.advanced(by: Int(startFrame)), count: Int(segLen))
            }
            playerNode.scheduleBuffer(seg, at: nil, options: []) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handlePlaybackFinished()
                }
            }
        }
        playStartFrame = startFrame
        playerNode.play()
    }

    private func handlePlaybackFinished() {
        // 真正自然结束(不是 stop/pause 触发的 buffer cancel)
        // 检查 currentFrame 是否接近末尾
        guard let buffer = audioBuffer else { return }
        let total = AVAudioFramePosition(buffer.frameLength)
        let cur = currentFrame()
        if cur >= total - 100 {
            stopPositionTimer()
            pausedFrame = 0
            positionMs = 0
            state = .ready
        }
    }

    private func stopInternal() {
        stopPositionTimer()
        if playerNode.isPlaying {
            playerNode.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        pausedFrame = 0
    }

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickPosition()
            }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func tickPosition() {
        guard let buffer = audioBuffer else { return }
        let cur = currentFrame()
        let sampleRate = buffer.format.sampleRate
        positionMs = framesToMs(cur, sampleRate: sampleRate)
    }

    /// 当前播放帧位置(absolute over the original buffer)
    private func currentFrame() -> AVAudioFramePosition {
        guard playerNode.isPlaying,
              let lastRender = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: lastRender) else {
            return pausedFrame
        }
        return playStartFrame + playerTime.sampleTime
    }

    private func framesToMs(_ frames: AVAudioFramePosition, sampleRate: Double) -> UInt64 {
        guard sampleRate > 0 else { return 0 }
        let secs = Double(frames) / sampleRate
        return UInt64(max(0, secs * 1000))
    }
}

// MARK: - Helpers

extension SessionAudioPlayer {
    var isReadyToPlay: Bool {
        switch state {
        case .ready, .paused, .playing:
            return true
        default:
            return false
        }
    }

    var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let msg) = state { return msg }
        return nil
    }

    /// 0..1
    var progress: Double {
        guard durationMs > 0 else { return 0 }
        return min(1.0, Double(positionMs) / Double(durationMs))
    }

    static func formatTime(_ ms: UInt64) -> String {
        let total = Int(ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
