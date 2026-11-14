// CityAudioExport.swift
// 给城的档案馆导出音频:把一场录音的音频每五分钟切一段,每段编成一个能单独
// 播放的 AAC `.m4a`,连同它在录音时间线上的起点、长度和每秒的音量。
//
// 这是 App 里唯一为档案馆碰音频的地方(scripts/test_share_no_audio_gate.sh
// 第 6 层守着):别的 `City*.swift` 不读采样、不编码。导出只在 core 的
// `cityAudioPlan` 说「可以交」以后才做 —— 那一问在 `CityAudioExportRun` 里,
// 每一段之前都问一遍。链接、发送副本、设备同步、附近递稿照旧不带音频,它们
// 够不到这里。
//
// 几条定下来的:
//   - 时间线就是存下来的音频自己的帧数:第 n 毫秒 = 第 n × 采样率 ÷ 1000 帧。
//     文字稿句子的时刻用的是同一个钟(core 按推进去的音频帧数给句子定时刻;
//     暂停时不推音频,两边都不走;引擎重启时补的静音也是推进去的帧)。所以
//     一段的 `t0Ms` 就是它第一帧的位置,不另算;
//   - 音频按存下来的分钟块读(一次一分钟),中间缺了一块就补等长的静音,后面
//     的不会往前挪;
//   - 编成单声道 AAC-LC,采样率不变,码率取编码器在这个采样率下不超过
//     64 kbps 的最高一档(16 kHz 是 48 kbps,五分钟约 1.8 MB),索引放在
//     文件最前面;
//   - 音量照城自己录音时的算法:每 200 毫秒一个 RMS × 5(封顶 1),一秒里取
//     最大的,× 9 取整,得一个 0–9 的数字;
//   - 临时文件放在 App 的临时目录里,交完一段删一段,没编成也删。
// 都是不碰界面的纯函数和一个写文件的小类,可以单独测。

import AVFoundation
import CoreMedia
import Foundation

/// 存下来的 PCM 是什么样的。
nonisolated struct CityAudioExportFormat: Equatable, Sendable {
    var sampleRate: Int
    var channels: Int

    /// 第 `ms` 毫秒在第几帧。
    func frame(atMs ms: Int64) -> Int64 {
        ms * Int64(sampleRate) / 1_000
    }
}

/// 一段:段号、在录音时间线上的起点和长度。
nonisolated struct CityAudioExportPart: Equatable, Sendable {
    let n: UInt32
    let t0Ms: Int64
    let durMs: Int64
}

/// 一场录音在这台 Mac 上的音频:格式、总长,和按时间取 PCM 的办法。
nonisolated struct CityAudioExportRecording: Sendable {
    let format: CityAudioExportFormat
    /// 存下来的音频一共多长。
    let durationMs: Int64
    /// `[startMs, endMs)` 的 PCM:32 位浮点、小端、各声道交错。那一段没有
    /// 音频就给空的。
    let read: @Sendable (_ startMs: Int64, _ endMs: Int64) -> Data
}

/// 编好的一段。文件由拿到它的人删(`discard`)。
nonisolated struct CityAudioExportedPart: Equatable, Sendable {
    let url: URL
    let part: CityAudioExportPart
    /// 每秒一个 0–9。
    let levels: String
    let bytes: Int64
    /// 这一段里有多少帧是补的静音(那几分钟的音频读不到)。
    let paddedFrames: Int64

    /// 删掉这一段:它自己的那个文件夹,连同编码器可能留在旁边的东西。
    func discard() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

nonisolated enum CityAudioExportError: Error, Equatable {
    /// 读到的字节数和说好的格式对不上:宁可不交,也不把变了调的声音放进
    /// 公开的档案。
    case formatMismatch
    /// 这一段一帧都读不到:音频已经不在这台 Mac 上了。
    case nothingToRead
    /// 这个采样率编不了 AAC。
    case unsupportedFormat
    /// core 的计划没说可以交:不导出。
    case notCleared
    case writeFailed(String)
}

nonisolated enum CityAudioExport {
    /// 存下来的音频按分钟分块;读也按分钟读,一次不超过一块。
    static let sliceMs: Int64 = 60_000
    /// 码率不超过这个数:城自己录音用的也是它。
    static let bitRateCeiling = 64_000
    /// 编码器收的最高采样率;再高的先按整数倍降下来。
    static let highestEncodedRate = 48_000

    // MARK: - 怎么切

    /// 一共几段。最后一段可以短。
    static func partCount(durationMs: Int64, partMs: Int64) -> UInt32 {
        guard durationMs > 0, partMs > 0 else { return 0 }
        return UInt32(clamping: (durationMs + partMs - 1) / partMs)
    }

    /// 还没交的那几段,从小到大。第 n 段从 n × `partMs` 开始。
    static func parts(durationMs: Int64, partMs: Int64, filed: [UInt32]) -> [CityAudioExportPart] {
        let total = partCount(durationMs: durationMs, partMs: partMs)
        let done = Set(filed)
        return (0..<total).compactMap { n in
            guard done.contains(n) == false else { return nil }
            let start = Int64(n) * partMs
            return CityAudioExportPart(n: n, t0Ms: start, durMs: min(partMs, durationMs - start))
        }
    }

    // MARK: - 多长

    /// 存下来的音频实际到哪。`hintMs` 是录音自己记的时长,只当从哪找起:从它
    /// 落在的那一分钟往后找到头、往前找到有音频的最后一分钟。读到的字节数和
    /// 格式对不上就抛错。
    static func measure(
        hintMs: Int64,
        format: CityAudioExportFormat,
        read: (_ startMs: Int64, _ endMs: Int64) -> Data
    ) throws -> Int64 {
        guard format.sampleRate > 0, format.channels > 0 else { throw CityAudioExportError.formatMismatch }
        let full = format.frame(atMs: sliceMs)
        func frames(inMinute minute: Int64) throws -> Int64 {
            let data = read(minute * sliceMs, (minute + 1) * sliceMs)
            return try frameCount(of: data, format: format, atMost: full)
        }
        // 一天以外的不找:录音没有那么长的。
        let lastMinute: Int64 = 24 * 60
        var minute = min(lastMinute, max(0, (max(hintMs, 1) - 1) / sliceMs))
        var have = try frames(inMinute: minute)
        if have > 0 {
            while have == full, minute < lastMinute {
                let next = try frames(inMinute: minute + 1)
                if next == 0 { break }
                minute += 1
                have = next
            }
        } else {
            while have == 0, minute > 0 {
                minute -= 1
                have = try frames(inMinute: minute)
            }
        }
        guard have > 0 else { return 0 }
        // 后面还有音频的话,头一分钟要么整整一分钟,要么整块不在。短了一截
        // 说明采样率或声道数不是说的那样。
        if minute > 0 {
            let first = try frames(inMinute: 0)
            guard first == full || first == 0 else { throw CityAudioExportError.formatMismatch }
        }
        return minute * sliceMs + have * 1_000 / Int64(format.sampleRate)
    }

    /// 量出来的长度和录音自己记的对不对得上。录音记的时长就是存下来的帧数
    /// ÷ 采样率(core 在停止、导入时这样算),所以采样率或声道数拿错了,
    /// 两个数会差出一截:
    ///   - 量出来的比记的长:采样率拿低了;
    ///   - 量出来的不到一分钟、又比记的短一大截:采样率拿高了(够一分钟的
    ///     在 `measure` 里已经对过头一分钟是不是整整一分钟)。
    /// 对不上就不交 —— 变了调的声音进了公开的档案撤不回来。录音没记时长
    /// (0)时无从比,放行。
    static func plausible(measuredMs: Int64, recordedMs: Int64) -> Bool {
        guard recordedMs > 0 else { return true }
        if measuredMs > recordedMs + max(2_000, recordedMs / 50) { return false }
        if measuredMs < sliceMs, measuredMs + max(2_000, recordedMs / 5) < recordedMs { return false }
        return true
    }

    /// 一块 PCM 有几帧;不是整帧、或者比要的还多,就是格式不对。
    static func frameCount(of data: Data, format: CityAudioExportFormat, atMost limit: Int64) throws -> Int64 {
        let bytesPerFrame = format.channels * MemoryLayout<Float32>.size
        guard bytesPerFrame > 0, data.count % bytesPerFrame == 0 else {
            throw CityAudioExportError.formatMismatch
        }
        let frames = Int64(data.count / bytesPerFrame)
        guard frames <= limit else { throw CityAudioExportError.formatMismatch }
        return frames
    }

    // MARK: - 采样

    /// 交错的 32 位浮点 PCM 混成单声道,正好 `frames` 帧:不够的在后面补静音
    /// (后面的音频不往前挪),多的不要。
    static func mono(_ data: Data, channels: Int, frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, frames))
        guard channels > 0, frames > 0 else { return out }
        let available = min(frames, data.count / (channels * MemoryLayout<Float32>.size))
        guard available > 0 else { return out }
        data.withUnsafeBytes { raw in
            for frame in 0..<available {
                var sum: Float = 0
                for channel in 0..<channels {
                    let offset = (frame * channels + channel) * MemoryLayout<Float32>.size
                    let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    sum += Float(bitPattern: UInt32(littleEndian: bits))
                }
                out[frame] = sum / Float(channels)
            }
        }
        return out
    }

    /// 采样率高过编码器收的,按整数倍降:每 `factor` 帧取平均。
    static func decimationFactor(sampleRate: Int) -> Int {
        guard sampleRate > highestEncodedRate else { return 1 }
        return (sampleRate + highestEncodedRate - 1) / highestEncodedRate
    }

    static func decimate(_ samples: [Float], by factor: Int) -> [Float] {
        guard factor > 1 else { return samples }
        var out = [Float]()
        out.reserveCapacity(samples.count / factor + 1)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + factor)
            var sum: Float = 0
            for position in index..<end { sum += samples[position] }
            out.append(sum / Float(end - index))
            index = end
        }
        return out
    }

    static func pcm16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
            return Int16((clamped * 32_767).rounded())
        }
    }

    // MARK: - 码率

    /// 这个采样率下单声道 AAC 用多少码率:编码器肯收的、不超过
    /// `bitRateCeiling` 的最高一档。问不到就按采样率估。
    static func bitRate(sampleRate: Int) -> Int {
        let allowed = applicableBitRates(sampleRate: sampleRate).filter { $0 <= bitRateCeiling }
        if let best = allowed.max() { return best }
        if sampleRate < 12_000 { return 24_000 }
        return sampleRate < 22_050 ? 48_000 : bitRateCeiling
    }

    static func applicableBitRates(sampleRate: Int) -> [Int] {
        guard let pcm = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else { return [] }
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let aac = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: pcm, to: aac)
        else { return [] }
        return (converter.applicableEncodeBitRates ?? []).map(\.intValue)
    }

    // MARK: - 一段

    /// 临时文件放哪:App 的临时目录下自己的一个文件夹。
    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("city-audio-export", isDirectory: true)
    }

    /// 上一回没来得及删的(中途退出、崩溃)清掉。不留编好的音频在盘上。
    static func sweep(_ directory: URL = temporaryDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 把一段导出成一个 `.m4a`。要拿着 core 刚给的计划来:计划没说可以交
    /// (没登录、文字还没交、设置关着、这一场单独关了)就不导出,一帧都不读。
    /// 没编成不留文件。整段一帧都读不到就抛 `nothingToRead`:音频没了,不拿
    /// 一段静音去交。
    static func export(
        _ part: CityAudioExportPart,
        from recording: CityAudioExportRecording,
        cityAudioPlan plan: FfiCityAudioPlan,
        into directory: URL = temporaryDirectory
    ) throws -> CityAudioExportedPart {
        guard plan.upload else { throw CityAudioExportError.notCleared }
        let format = recording.format
        guard format.sampleRate > 0, format.channels > 0, part.durMs > 0 else {
            throw CityAudioExportError.unsupportedFormat
        }
        let factor = decimationFactor(sampleRate: format.sampleRate)
        guard format.sampleRate % factor == 0 else { throw CityAudioExportError.unsupportedFormat }
        let outputRate = format.sampleRate / factor

        // 一段一个自己的文件夹:写文件的系统组件会在成品旁边放它自己的临时
        // 文件(里面也是这段音频),连文件夹一起删才删得干净。
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("part.m4a")
        var writing: CityAudioExportWriter?
        do {
            let writer = try CityAudioExportWriter(url: url, sampleRate: outputRate)
            writing = writer
            var meter = CityAudioExportLevelMeter(sampleRate: outputRate)
            var cursor = part.t0Ms
            let end = part.t0Ms + part.durMs
            var padded: Int64 = 0
            var readFrames: Int64 = 0
            while cursor < end {
                let next = min(end, (cursor / sliceMs + 1) * sliceMs)
                let wanted = format.frame(atMs: next) - format.frame(atMs: cursor)
                if wanted > 0 {
                    let data = recording.read(cursor, next)
                    let have = try frameCount(of: data, format: format, atMost: Int64.max)
                    readFrames += min(have, wanted)
                    padded += max(0, wanted - have)
                    let samples = decimate(
                        mono(data, channels: format.channels, frames: Int(wanted)),
                        by: factor
                    )
                    meter.add(samples)
                    try writer.append(pcm16(samples))
                }
                cursor = next
            }
            guard readFrames > 0 else { throw CityAudioExportError.nothingToRead }
            try writer.finish()
            writing = nil
            // 成品旁边不留别的。
            let beside = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )) ?? []
            for other in beside where other.lastPathComponent != url.lastPathComponent {
                try? FileManager.default.removeItem(at: other)
            }
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            guard size > 0 else { throw CityAudioExportError.writeFailed("empty file") }
            return CityAudioExportedPart(
                url: url,
                part: part,
                levels: meter.finish(),
                bytes: size,
                paddedFrames: padded
            )
        } catch {
            writing?.cancel()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

// MARK: - 音量

/// 每秒一个 0–9 的音量,一边读一边算。算法照城自己的录音:一秒分五格,每格
/// 的 RMS × 5(封顶 1),取五格里最大的,× 9 四舍五入。
nonisolated struct CityAudioExportLevelMeter {
    /// 一段最多记这么多秒(core 收的上限)。
    static let limit = 3_600

    private let secondFrames: Int
    private let windowFrames: Int
    private var windowSum: Double = 0
    private var windowCount = 0
    private var secondCount = 0
    private var secondPeak: Double = 0
    private var digits: [UInt8] = []

    init(sampleRate: Int) {
        secondFrames = max(1, sampleRate)
        windowFrames = max(1, sampleRate / 5)
    }

    mutating func add(_ samples: [Float]) {
        for sample in samples {
            let value = Double(sample)
            windowSum += value * value
            windowCount += 1
            secondCount += 1
            if windowCount == windowFrames { closeWindow() }
            if secondCount == secondFrames { closeSecond() }
        }
    }

    /// 收尾:不满一秒的零头也算一秒。
    mutating func finish() -> String {
        if secondCount > 0 { closeSecond() }
        return String(decoding: digits, as: UTF8.self)
    }

    private mutating func closeWindow() {
        guard windowCount > 0 else { return }
        let rms = (windowSum / Double(windowCount)).squareRoot()
        secondPeak = max(secondPeak, min(1, rms * 5))
        windowSum = 0
        windowCount = 0
    }

    private mutating func closeSecond() {
        closeWindow()
        if digits.count < Self.limit {
            let digit = min(9, Int((secondPeak * 9).rounded()))
            digits.append(UInt8(ascii: "0") + UInt8(digit))
        }
        secondPeak = 0
        secondCount = 0
    }
}

// MARK: - 写文件

/// 把单声道 16 位采样写成一个 AAC `.m4a`。索引(moov)在文件最前面,拿到开头
/// 就能播。一个文件一个实例,在后台线程上用。
nonisolated final class CityAudioExportWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private let sampleRate: Int
    private var written: Int64 = 0
    /// 一次交给编码器这么多帧。
    private static let batch = 16_384

    init(url: URL, sampleRate: Int) throws {
        self.sampleRate = sampleRate
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw CityAudioExportError.writeFailed(String(describing: error))
        }
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: CityAudioExport.bitRate(sampleRate: sampleRate),
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw CityAudioExportError.unsupportedFormat
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CityAudioExportError.unsupportedFormat }
        writer.add(input)

        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw CityAudioExportError.unsupportedFormat }

        guard writer.startWriting() else {
            throw CityAudioExportError.writeFailed(String(describing: writer.error))
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.format = format
    }

    func append(_ samples: [Int16]) throws {
        var offset = 0
        while offset < samples.count {
            let count = min(Self.batch, samples.count - offset)
            try appendBatch(samples, offset: offset, count: count)
            offset += count
        }
    }

    private func appendBatch(_ samples: [Int16], offset: Int, count: Int) throws {
        let bytes = count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            throw CityAudioExportError.writeFailed("block buffer \(status)")
        }
        status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress! + offset * MemoryLayout<Int16>.size,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: bytes
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw CityAudioExportError.writeFailed("block copy \(status)")
        }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw CityAudioExportError.writeFailed("sample buffer \(status)")
        }
        // 编码器忙的时候等它;写的人在后台线程上,等得起。
        var waited = 0
        while input.isReadyForMoreMediaData == false {
            guard writer.status == .writing, waited < 30_000 else {
                throw CityAudioExportError.writeFailed(String(describing: writer.error))
            }
            usleep(2_000)
            waited += 2
        }
        guard input.append(sample) else {
            throw CityAudioExportError.writeFailed(String(describing: writer.error))
        }
        written += Int64(count)
    }

    /// 不写了:让编码器把手上的东西丢掉。
    func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    func finish() throws {
        guard written > 0 else {
            cancel()
            throw CityAudioExportError.nothingToRead
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw CityAudioExportError.writeFailed(String(describing: writer.error))
        }
    }
}
