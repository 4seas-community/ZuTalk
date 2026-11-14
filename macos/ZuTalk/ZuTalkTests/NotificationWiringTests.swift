// NotificationWiringTests.swift
// 验证应用级事件通知的命名和基本投递。
//
// 1. **静态防御**: NotificationCatalog 列出所有 zutalk* notification name.
//    每个 name 必须在 production source 里既有 post 也有 addObserver / publisher.
//
// 2. **运行时防御**: 这个测试文件 — 验证 notification name 拼写、name uniqueness,
//    以及 addObserver + post 的基本 round-trip 工作正常.
//
// IntegrityChecks 在应用启动时验证运行时配置。

import XCTest
@testable import ZuTalk

@MainActor
final class NotificationWiringTests: XCTestCase {

    var observers: [NSObjectProtocol] = []

    override func setUp() async throws {
        try await super.setUp()
        observers = []
    }

    override func tearDown() async throws {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        observers = []
        try await super.tearDown()
    }

    // MARK: - 所有 zutalk 自定义 notification 都存在 + 名字唯一

    func testAllZuTalkNotificationsHaveUniqueNames() {
        let allNames: [Notification.Name] = [
            .zutalkSessionUpdated,
            .zutalkPermissionsMayHaveChanged,
        ]
        let raw = allNames.map(\.rawValue)
        let unique = Set(raw)
        XCTAssertEqual(
            raw.count,
            unique.count,
            "zutalk notification names must be unique, found duplicates: \(raw)"
        )
        // 没空字符串
        for name in raw {
            XCTAssertFalse(name.isEmpty, "notification name should not be empty")
            XCTAssertTrue(
                name.hasPrefix("ZuTalk"),
                "notification name should start with ZuTalk prefix, got: \(name)"
            )
        }
    }

    // MARK: - addObserver + post round-trip (验证 NotificationCenter 工作)

    func testAddObserverAndPost_zutalkPermissionsMayHaveChanged_roundtrip() {
        var received = false
        let obs = NotificationCenter.default.addObserver(
            forName: .zutalkPermissionsMayHaveChanged,
            object: nil,
            queue: nil
        ) { _ in received = true }
        observers.append(obs)

        NotificationCenter.default.post(name: .zutalkPermissionsMayHaveChanged, object: nil)
        XCTAssertTrue(received)
    }

    func testAddObserverAndPost_zutalkSessionUpdated_carriesObject() {
        var receivedSessionId: String?
        let obs = NotificationCenter.default.addObserver(
            forName: .zutalkSessionUpdated,
            object: nil,
            queue: nil
        ) { note in
            receivedSessionId = note.object as? String
        }
        observers.append(obs)

        NotificationCenter.default.post(
            name: .zutalkSessionUpdated,
            object: "session-abc-123"
        )
        XCTAssertEqual(receivedSessionId, "session-abc-123")
    }

    // MARK: - removeObserver 真的能取消订阅 (内存安全)

    func testRemoveObserver_stopsReceiving() {
        var count = 0
        let obs = NotificationCenter.default.addObserver(
            forName: .zutalkSessionUpdated,
            object: nil,
            queue: nil
        ) { _ in count += 1 }

        NotificationCenter.default.post(name: .zutalkSessionUpdated, object: "session-1")
        XCTAssertEqual(count, 1)

        NotificationCenter.default.removeObserver(obs)
        NotificationCenter.default.post(name: .zutalkSessionUpdated, object: "session-2")
        XCTAssertEqual(count, 1, "removeObserver should stop further deliveries")
    }
}

// MARK: - 0.8.3 city: 交到档案馆的音频

import AVFoundation

/// Synthetic recordings for the exporter: a 440 Hz tone whose loudness
/// follows a function of time, as 32-bit float PCM — what the core hands out.
private enum CityAudioFixture {
    static func pcm(
        fromMs: Int64,
        toMs: Int64,
        totalMs: Int64,
        rate: Int,
        channels: Int,
        amplitude: @Sendable (Double) -> Float
    ) -> Data {
        let end = min(toMs, totalMs)
        guard end > fromMs else { return Data() }
        let first = fromMs * Int64(rate) / 1_000
        let last = end * Int64(rate) / 1_000
        var samples = [Float32]()
        samples.reserveCapacity(Int(last - first) * channels)
        for frame in first..<last {
            let t = Double(frame) / Double(rate)
            let value = Float32(sin(2 * Double.pi * 440 * t)) * amplitude(t)
            for _ in 0..<channels { samples.append(value) }
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// A recording `seconds` long. `missing` says which reads come back empty
    /// (by the millisecond they start at): a minute whose audio is gone.
    static func recording(
        seconds: Double,
        rate: Int = 16_000,
        channels: Int = 1,
        missing: @escaping @Sendable (Int64) -> Bool = { _ in false },
        amplitude: @escaping @Sendable (Double) -> Float = { _ in 0.5 }
    ) -> CityAudioExportRecording {
        let total = Int64(seconds * 1_000)
        return CityAudioExportRecording(
            format: CityAudioExportFormat(sampleRate: rate, channels: channels),
            durationMs: total,
            read: { startMs, endMs in
                guard missing(startMs) == false else { return Data() }
                return pcm(
                    fromMs: startMs,
                    toMs: endMs,
                    totalMs: total,
                    rate: rate,
                    channels: channels,
                    amplitude: amplitude
                )
            }
        )
    }

    static func plan(
        upload: Bool = true,
        hold: String? = nil,
        filed: [UInt32] = [],
        partMs: Int64 = 300_000
    ) -> FfiCityAudioPlan {
        FfiCityAudioPlan(
            upload: upload,
            holdCode: hold,
            due: upload,
            partMs: partMs,
            maxPartBytes: 16_777_216,
            mime: "audio/mp4",
            partsPlanned: 0,
            partsFiled: filed
        )
    }

    static func filing(
        _ state: FfiCityFilingState = .filed,
        session: String = "session-1",
        wanted: Bool = true,
        withheld: Bool = false,
        due: Bool = false,
        planned: UInt32 = 0,
        filed: UInt32 = 0,
        audioError: String? = nil,
        retryAt: Int64? = nil,
        changed: UInt32 = 0,
        errorCode: String? = nil
    ) -> FfiCityFiling {
        FfiCityFiling(
            sessionId: session,
            eventId: "event-1",
            eventTitle: "Language Exchange",
            eventStartMs: 1_794_547_200_000,
            channelTitle: nil,
            state: state,
            filedAtEpoch: state == .filed ? 1_794_550_000 : nil,
            signerName: "Sam",
            languages: [FfiCityLanguageCount(language: "en", sentences: 412)],
            speakers: 2,
            marks: 0,
            changedSentences: changed,
            errorCode: errorCode,
            webUrl: nil,
            audioWanted: wanted,
            audioWithheld: withheld,
            audioDue: due,
            audioPartsPlanned: planned,
            audioPartsFiled: filed,
            audioErrorCode: audioError,
            audioRetryAtEpoch: retryAt
        )
    }

    /// The names of a file's top-level MPEG-4 boxes, in order.
    static func boxes(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var names: [String] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            names.append(String(decoding: data[offset + 4..<offset + 8], as: UTF8.self))
            guard size >= 8 else { break }
            offset += size
        }
        return names
    }

    /// The decoded samples of an exported part.
    static func decode(_ url: URL) throws -> (samples: [Float], rate: Double, formatID: AudioFormatID, channels: UInt32) {
        let file = try AVAudioFile(forReading: url)
        let description = file.fileFormat.streamDescription.pointee
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw CocoaError(.fileReadUnknown)
        }
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        let samples = buffer.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: count)) } ?? []
        return (samples, file.processingFormat.sampleRate, description.mFormatID, description.mChannelsPerFrame)
    }

    static func rms(_ samples: [Float], from: Double, to: Double, rate: Double) -> Float {
        let lower = max(0, Int(from * rate))
        let upper = min(samples.count, Int(to * rate))
        guard upper > lower else { return 0 }
        let sum = samples[lower..<upper].reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(upper - lower)).squareRoot()
    }
}

private final class CityAudioCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The exporter: how a recording is cut, what one part's file is, what its
/// levels say, and that nothing is read or left behind when it should not be.
final class CityAudioExportTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("city-audio-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    func testARecordingIsCutIntoFiveMinuteRangesWithAShortLastOne() {
        let part: Int64 = 300_000
        XCTAssertEqual(CityAudioExport.partCount(durationMs: 0, partMs: part), 0)
        XCTAssertEqual(CityAudioExport.partCount(durationMs: 1, partMs: part), 1)
        XCTAssertEqual(CityAudioExport.partCount(durationMs: 300_000, partMs: part), 1)
        XCTAssertEqual(CityAudioExport.partCount(durationMs: 300_001, partMs: part), 2)
        // Two hours: the 24 parts of "audio 3/24".
        XCTAssertEqual(CityAudioExport.partCount(durationMs: 7_200_000, partMs: part), 24)
        XCTAssertEqual(CityAudioExport.partCount(durationMs: 1_000, partMs: 0), 0)

        XCTAssertEqual(
            CityAudioExport.parts(durationMs: 725_000, partMs: part, filed: []),
            [
                CityAudioExportPart(n: 0, t0Ms: 0, durMs: 300_000),
                CityAudioExportPart(n: 1, t0Ms: 300_000, durMs: 300_000),
                CityAudioExportPart(n: 2, t0Ms: 600_000, durMs: 125_000),
            ]
        )
        // Part n always starts at n × the part length, whatever was filed.
        XCTAssertEqual(
            CityAudioExport.parts(durationMs: 725_000, partMs: part, filed: [0, 2]),
            [CityAudioExportPart(n: 1, t0Ms: 300_000, durMs: 300_000)]
        )
        XCTAssertEqual(CityAudioExport.parts(durationMs: 725_000, partMs: part, filed: [2, 1, 0]), [])
        XCTAssertEqual(CityAudioExport.parts(durationMs: 0, partMs: part, filed: []), [])
    }

    func testAPartIsASelfContainedAACFileWithItsIndexInFront() throws {
        // Loud for two seconds, silent for two, loud for two.
        let recording = CityAudioFixture.recording(seconds: 6, amplitude: { t in
            (2..<4).contains(t) ? 0 : 0.5
        })
        let part = CityAudioExportPart(n: 0, t0Ms: 0, durMs: 6_000)

        let exported = try CityAudioExport.export(
            part,
            from: recording,
            cityAudioPlan: CityAudioFixture.plan(),
            into: directory
        )

        XCTAssertEqual(exported.part, part)
        XCTAssertEqual(exported.paddedFrames, 0)
        XCTAssertEqual(exported.url.pathExtension, "m4a")
        XCTAssertTrue(exported.url.path.hasPrefix(directory.path))
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: exported.url.path)[.size] as? NSNumber
        ).int64Value
        XCTAssertEqual(size, exported.bytes)
        XCTAssertGreaterThan(size, 1_000)
        // Six seconds at 48 kbps is about 36 KB; nowhere near the 16 MiB a part may be.
        XCTAssertLessThan(size, 120_000)

        // The index (moov) sits before the samples (mdat): playable from the first bytes.
        let boxes = try CityAudioFixture.boxes(exported.url)
        XCTAssertEqual(boxes.first, "ftyp")
        let moov = try XCTUnwrap(boxes.firstIndex(of: "moov"))
        let mdat = try XCTUnwrap(boxes.firstIndex(of: "mdat"))
        XCTAssertLessThan(moov, mdat)

        // It opens with AVFoundation as mono AAC of the right length, and the
        // silence is where it was.
        let decoded = try CityAudioFixture.decode(exported.url)
        XCTAssertEqual(decoded.formatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(decoded.channels, 1)
        XCTAssertEqual(decoded.rate, 16_000)
        XCTAssertEqual(Double(decoded.samples.count) / decoded.rate, 6, accuracy: 0.15)
        XCTAssertGreaterThan(CityAudioFixture.rms(decoded.samples, from: 0.5, to: 1.5, rate: decoded.rate), 0.2)
        XCTAssertLessThan(CityAudioFixture.rms(decoded.samples, from: 2.5, to: 3.5, rate: decoded.rate), 0.02)
        XCTAssertGreaterThan(CityAudioFixture.rms(decoded.samples, from: 4.5, to: 5.5, rate: decoded.rate), 0.2)

        // One digit per second: loud is high, silence is zero.
        XCTAssertEqual(exported.levels, "990099")

        // Nothing sits beside the finished file, and discarding it leaves nothing.
        let folder = exported.url.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["part.m4a"])
        exported.discard()
        XCTAssertEqual(leftovers(), [])
    }

    func testAPartStartsWhereItsRangeStartsOnTheRecordingsTimeline() throws {
        // A beep in second 7 only; the part is [6 s, 9 s).
        let recording = CityAudioFixture.recording(seconds: 10, amplitude: { t in
            (7..<8).contains(t) ? 0.5 : 0
        })
        let exported = try CityAudioExport.export(
            CityAudioExportPart(n: 2, t0Ms: 6_000, durMs: 3_000),
            from: recording,
            cityAudioPlan: CityAudioFixture.plan(),
            into: directory
        )
        XCTAssertEqual(exported.levels, "090")
        let decoded = try CityAudioFixture.decode(exported.url)
        XCTAssertLessThan(CityAudioFixture.rms(decoded.samples, from: 0.2, to: 0.8, rate: decoded.rate), 0.02)
        XCTAssertGreaterThan(CityAudioFixture.rms(decoded.samples, from: 1.2, to: 1.8, rate: decoded.rate), 0.2)
        XCTAssertLessThan(CityAudioFixture.rms(decoded.samples, from: 2.2, to: 2.8, rate: decoded.rate), 0.02)
    }

    func testAMinuteThatCannotBeReadBecomesSilenceAndWhatFollowsStaysInPlace() throws {
        // 130 seconds, loud throughout; the second minute's audio is gone.
        let recording = CityAudioFixture.recording(
            seconds: 130,
            missing: { $0 >= 60_000 && $0 < 120_000 }
        )
        let exported = try CityAudioExport.export(
            CityAudioExportPart(n: 0, t0Ms: 0, durMs: 130_000),
            from: recording,
            cityAudioPlan: CityAudioFixture.plan(),
            into: directory
        )
        XCTAssertEqual(exported.paddedFrames, 60 * 16_000)
        let levels = Array(exported.levels)
        XCTAssertEqual(levels.count, 130)
        XCTAssertTrue(levels[0..<60].allSatisfy { $0 == "9" })
        XCTAssertTrue(levels[60..<120].allSatisfy { $0 == "0" })
        // The last ten seconds are still the last ten seconds.
        XCTAssertTrue(levels[120..<130].allSatisfy { $0 == "9" })
    }

    func testNothingIsReadWithoutAPlanThatSaysUpload() {
        let reads = CityAudioCounter()
        let recording = CityAudioExportRecording(
            format: CityAudioExportFormat(sampleRate: 16_000, channels: 1),
            durationMs: 5_000,
            read: { _, _ in
                reads.bump()
                return Data()
            }
        )
        for code in ["city.error.audio_off", "city.error.audio_withheld", "city.error.signed_out"] {
            XCTAssertThrowsError(
                try CityAudioExport.export(
                    CityAudioExportPart(n: 0, t0Ms: 0, durMs: 5_000),
                    from: recording,
                    cityAudioPlan: CityAudioFixture.plan(upload: false, hold: code),
                    into: directory
                )
            ) { error in
                XCTAssertEqual(error as? CityAudioExportError, .notCleared)
            }
        }
        XCTAssertEqual(reads.count, 0)
        XCTAssertEqual(leftovers(), [])
    }

    func testAPartWithNoAudioAtAllIsNeitherWrittenNorLeftBehind() {
        let gone = CityAudioFixture.recording(seconds: 5, missing: { _ in true })
        XCTAssertThrowsError(
            try CityAudioExport.export(
                CityAudioExportPart(n: 0, t0Ms: 0, durMs: 5_000),
                from: gone,
                cityAudioPlan: CityAudioFixture.plan(),
                into: directory
            )
        ) { error in
            XCTAssertEqual(error as? CityAudioExportError, .nothingToRead)
        }
        XCTAssertEqual(leftovers(), [])

        // Bytes that are not whole frames of the stated format: refuse, and
        // leave nothing behind.
        let odd = CityAudioExportRecording(
            format: CityAudioExportFormat(sampleRate: 16_000, channels: 2),
            durationMs: 1_000,
            read: { _, _ in Data(count: 4 * 101) }
        )
        XCTAssertThrowsError(
            try CityAudioExport.export(
                CityAudioExportPart(n: 0, t0Ms: 0, durMs: 1_000),
                from: odd,
                cityAudioPlan: CityAudioFixture.plan(),
                into: directory
            )
        ) { error in
            XCTAssertEqual(error as? CityAudioExportError, .formatMismatch)
        }
        XCTAssertEqual(leftovers(), [])
    }

    func testTheStoredAudioIsMeasuredFromWhateverTheRecordingSaysItsLengthIs() throws {
        let format = CityAudioExportFormat(sampleRate: 1_000, channels: 1)
        // 130.5 seconds of audio at 1 kHz: zeros are enough to count frames.
        let read: (Int64, Int64) -> Data = { startMs, endMs in
            let end = min(endMs, 130_500)
            return end > startMs ? Data(count: Int(end - startMs) * 4) : Data()
        }
        for hint in [Int64(130_500), 10_000, 0, 400_000, 120_000, 60_000] {
            XCTAssertEqual(
                try CityAudioExport.measure(hintMs: hint, format: format, read: read),
                130_500,
                "hint \(hint)"
            )
        }
        XCTAssertEqual(try CityAudioExport.measure(hintMs: 90_000, format: format) { _, _ in Data() }, 0)

        // More frames in a minute than the format allows: the rate or the
        // channel count is not what was said.
        XCTAssertThrowsError(
            try CityAudioExport.measure(hintMs: 30_000, format: format) { _, _ in Data(count: 61_000 * 4) }
        )
        // A first minute that is short while later minutes exist: likewise.
        XCTAssertThrowsError(
            try CityAudioExport.measure(hintMs: 100_000, format: format) { startMs, _ in
                Data(count: (startMs < 120_000 ? 20_000 : 0) * 4)
            }
        )
        // Not whole samples.
        XCTAssertThrowsError(
            try CityAudioExport.measure(hintMs: 1_000, format: format) { _, _ in Data(count: 6) }
        )
    }

    func testAMeasuredLengthThatContradictsTheRecordingIsNotFiled() {
        XCTAssertTrue(CityAudioExport.plausible(measuredMs: 130_000, recordedMs: 130_000))
        XCTAssertTrue(CityAudioExport.plausible(measuredMs: 129_950, recordedMs: 130_000))
        XCTAssertTrue(CityAudioExport.plausible(measuredMs: 5_000, recordedMs: 0))
        // Three times as long as recorded: the rate was taken too low.
        XCTAssertFalse(CityAudioExport.plausible(measuredMs: 30_000, recordedMs: 10_000))
        // A third as long, under a minute: the rate was taken too high.
        XCTAssertFalse(CityAudioExport.plausible(measuredMs: 20_000, recordedMs: 60_000))
        // A minute or more was already checked frame for frame by `measure`.
        XCTAssertTrue(CityAudioExport.plausible(measuredMs: 180_000, recordedMs: 600_000))
    }

    func testSpeechStaysClearAndAPartStaysFarBelowTheLimit() {
        XCTAssertEqual(CityAudioExport.bitRate(sampleRate: 16_000), 48_000)
        XCTAssertEqual(CityAudioExport.bitRate(sampleRate: 44_100), 64_000)
        XCTAssertEqual(CityAudioExport.bitRate(sampleRate: 48_000), 64_000)
        for rate in [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000] {
            let bitRate = CityAudioExport.bitRate(sampleRate: rate)
            XCTAssertLessThanOrEqual(bitRate, CityAudioExport.bitRateCeiling, "\(rate)")
            XCTAssertGreaterThanOrEqual(bitRate, 24_000, "\(rate)")
            // Five minutes at this rate, doubled for good measure, is still
            // under a third of the 16 MiB a part may be.
            XCTAssertLessThan(bitRate / 8 * 300 * 2, 16_777_216 / 3, "\(rate)")
        }
    }

    func testLevelsAreOneDigitPerSecondAndFollowLoudness() {
        var meter = CityAudioExportLevelMeter(sampleRate: 1_000)
        let second: (Float) -> [Float] = { amplitude in
            (0..<1_000).map { Float(sin(2 * Double.pi * 50 * Double($0) / 1_000)) * amplitude }
        }
        meter.add(second(0.5))
        meter.add(second(0))
        meter.add(second(0.05))
        meter.add(Array(second(0.5).prefix(500)))
        // Loud, silent, quiet (RMS 0.035 × 5 × 9 ≈ 2), and half a second counts as one.
        XCTAssertEqual(meter.finish(), "9029")

        // Never more digits than the core accepts.
        var long = CityAudioExportLevelMeter(sampleRate: 10)
        long.add([Float](repeating: 0.5, count: 37_000))
        XCTAssertEqual(long.finish().count, CityAudioExportLevelMeter.limit)
        XCTAssertEqual(CityAudioExportLevelMeter.limit, 3_600)
    }

    func testStereoIsMixedDownAndVeryHighRatesComeDown() {
        let stereo: [Float32] = [1, 0, 0.5, 0.5, -1, 1]
        let data = stereo.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(CityAudioExport.mono(data, channels: 2, frames: 3), [0.5, 0.5, 0])
        // Short of frames: silence after, never a shift.
        XCTAssertEqual(CityAudioExport.mono(data, channels: 2, frames: 5), [0.5, 0.5, 0, 0, 0])
        XCTAssertEqual(CityAudioExport.mono(data, channels: 2, frames: 2), [0.5, 0.5])

        XCTAssertEqual(CityAudioExport.decimationFactor(sampleRate: 16_000), 1)
        XCTAssertEqual(CityAudioExport.decimationFactor(sampleRate: 48_000), 1)
        XCTAssertEqual(CityAudioExport.decimationFactor(sampleRate: 96_000), 2)
        XCTAssertEqual(CityAudioExport.decimationFactor(sampleRate: 192_000), 4)
        XCTAssertEqual(CityAudioExport.decimate([1, 3, 5, 7, 9], by: 2), [2, 6, 9])
        XCTAssertEqual(CityAudioExport.pcm16([0, 1, -1, 2, -.infinity, .nan]), [0, 32_767, -32_767, 32_767, 0, 0])
    }

    func testTemporaryFilesFromAnEarlierRunAreSweptAway() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("stale.m4a")
        try Data([1, 2, 3]).write(to: stale)
        CityAudioExport.sweep(directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        // And the place they go is inside the app's temporary directory.
        XCTAssertTrue(
            CityAudioExport.temporaryDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path)
        )
    }
}

/// A core that files what it is given, or refuses, as the test says.
private final class FakeCityAudioCore: CityAudioExportFiling, CityAudioExportReading, @unchecked Sendable {
    struct Call: Equatable {
        let n: UInt32
        let total: UInt32
        let t0Ms: Int64
        let durMs: Int64
        let levels: String
        let path: String
        /// The file was there, and was MPEG-4, when the core was handed it.
        let wasMP4: Bool
    }

    private let lock = NSLock()
    var recording: CityAudioExportRecording?
    var openError: Error?
    var hold: String?
    /// From this many plan questions on, the answer is "do not file".
    var holdFromPlanCall: (count: Int, code: String)?
    var partMs: Int64 = 2_000
    var alreadyFiled: Set<UInt32> = []
    /// Parts the city answers with an audio error.
    var errors: [UInt32: String] = [:]
    /// Parts the core refuses outright.
    var refusals: [UInt32: String] = [:]
    private(set) var calls: [Call] = []
    private(set) var planCalls = 0
    private(set) var opens = 0

    func cityAudioPlan(sessionId: String) -> FfiCityAudioPlan {
        lock.lock()
        defer { lock.unlock() }
        planCalls += 1
        var code = hold
        if let late = holdFromPlanCall, planCalls >= late.count { code = late.code }
        return CityAudioFixture.plan(
            upload: code == nil,
            hold: code,
            filed: alreadyFiled.sorted(),
            partMs: partMs
        )
    }

    func cityFileAudioPart(
        sessionId: String,
        n: UInt32,
        total: UInt32,
        path: String,
        t0Ms: Int64,
        durMs: Int64,
        levels: String
    ) throws -> FfiCityFiling {
        lock.lock()
        defer { lock.unlock() }
        let head = (try? Data(contentsOf: URL(fileURLWithPath: path)).prefix(8)) ?? Data()
        calls.append(Call(
            n: n,
            total: total,
            t0Ms: t0Ms,
            durMs: durMs,
            levels: levels,
            path: path,
            wasMP4: head.count == 8 && String(decoding: head.suffix(4), as: UTF8.self) == "ftyp"
        ))
        if let refusal = refusals[n] {
            throw CoreError.ValidationFailed(message: refusal)
        }
        if errors[n] == nil { alreadyFiled.insert(n) }
        return CityAudioFixture.filing(
            session: sessionId,
            due: true,
            planned: total,
            filed: UInt32(alreadyFiled.count),
            audioError: errors[n]
        )
    }

    func open(sessionId: String) throws -> CityAudioExportRecording? {
        lock.lock()
        defer { lock.unlock() }
        opens += 1
        if let openError { throw openError }
        return recording
    }
}

/// Filing a recording's audio part by part: the order, where it stops, how it
/// resumes, and that an encoded file never outlives its part.
final class CityAudioExportRunTests: XCTestCase {
    private var directory: URL!
    private var core: FakeCityAudioCore!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("city-audio-run-\(UUID().uuidString)", isDirectory: true)
        core = FakeCityAudioCore()
        // Five seconds in two-second parts: 2 s, 2 s, 1 s.
        core.recording = CityAudioFixture.recording(seconds: 5)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var run: CityAudioExportRun {
        CityAudioExportRun(filing: core, audio: core, directory: directory)
    }

    private func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    func testEveryPartIsFiledInOrderWithItsPlaceOnTheTimeline() {
        var began: [UInt32] = []
        var progressed: [UInt32] = []
        let outcome = run.run(
            sessionId: "s",
            began: { began.append($0) },
            progress: { progressed.append($0.audioPartsFiled) }
        )

        XCTAssertEqual(core.calls.map(\.n), [0, 1, 2])
        XCTAssertEqual(core.calls.map(\.total), [3, 3, 3])
        XCTAssertEqual(core.calls.map(\.t0Ms), [0, 2_000, 4_000])
        XCTAssertEqual(core.calls.map(\.durMs), [2_000, 2_000, 1_000])
        XCTAssertEqual(core.calls.map(\.levels.count), [2, 2, 1])
        XCTAssertTrue(core.calls.allSatisfy(\.wasMP4))
        XCTAssertEqual(began, [3])
        XCTAssertEqual(progressed, [1, 2, 3])
        guard case .finished(let last?) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(last.audioPartsFiled, 3)
        // Each encoded file is gone once its part is filed.
        XCTAssertEqual(leftovers(), [])
        XCTAssertEqual(Set(core.calls.map(\.path)).count, 3)
    }

    func testARecordingStopsAtItsFirstAudioError() {
        for code in [
            "city.error.offline", "city.error.server", "city.error.audio_refused",
            "city.error.audio_too_big", "city.error.audio_daily_cap", "city.error.audio_server_full",
        ] {
            setUp()
            core.errors[1] = code
            let outcome = run.run(sessionId: "s")

            XCTAssertEqual(core.calls.map(\.n), [0, 1], code)
            guard case .stopped(let filing) = outcome else {
                XCTFail("\(code): \(outcome)")
                continue
            }
            XCTAssertEqual(filing.audioErrorCode, code)
            XCTAssertEqual(filing.audioPartsFiled, 1)
            XCTAssertEqual(leftovers(), [], code)
            tearDown()
        }
    }

    func testResumingFilesOnlyThePartsTheCityDoesNotHave() {
        core.alreadyFiled = [0, 1]
        let outcome = run.run(sessionId: "s")
        XCTAssertEqual(core.calls.map(\.n), [2])
        XCTAssertEqual(core.calls.first?.total, 3)
        XCTAssertEqual(core.calls.first?.t0Ms, 4_000)
        guard case .finished(let last?) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(last.audioPartsFiled, 3)

        // All there already: nothing is exported, nothing is sent.
        setUp()
        core.alreadyFiled = [0, 1, 2]
        XCTAssertEqual(run.run(sessionId: "s"), .finished(nil))
        XCTAssertEqual(core.calls, [])
        XCTAssertEqual(leftovers(), [])
    }

    func testTheAudioIsNotEvenOpenedWhileTheCoreSaysNotToFile() {
        for code in [
            "city.error.signed_out", "city.error.unbound", "city.error.audio_not_filed",
            "city.error.audio_off", "city.error.audio_withheld", "city.error.audio_daily_cap",
        ] {
            setUp()
            core.hold = code
            XCTAssertEqual(run.run(sessionId: "s"), .held(code: code))
            XCTAssertEqual(core.opens, 0, code)
            XCTAssertEqual(core.calls, [], code)
        }
    }

    func testSwitchingAudioOffBetweenPartsStopsBeforeTheNextOne() {
        // Asked once at the start, once before part 0, and before part 1 the
        // answer has changed.
        core.holdFromPlanCall = (3, "city.error.audio_withheld")
        let outcome = run.run(sessionId: "s")
        XCTAssertEqual(core.calls.map(\.n), [0])
        XCTAssertEqual(outcome, .held(code: "city.error.audio_withheld"))
        XCTAssertEqual(leftovers(), [])
    }

    func testAudioThatIsNoLongerOnThisMacIsAStateAndNothingIsSent() {
        core.recording = nil
        XCTAssertEqual(run.run(sessionId: "s"), .noAudio)
        XCTAssertEqual(core.calls, [])

        // The recording says five seconds, but every read comes back empty.
        setUp()
        core.recording = CityAudioFixture.recording(seconds: 5, missing: { _ in true })
        XCTAssertEqual(run.run(sessionId: "s"), .noAudio)
        XCTAssertEqual(core.calls, [])
        XCTAssertEqual(leftovers(), [])
    }

    func testBeingAskedToStopTakesEffectBetweenParts() {
        var asked = 0
        let outcome = run.run(sessionId: "s", shouldStop: {
            asked += 1
            return asked > 1
        })
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertEqual(core.calls.map(\.n), [0])
        XCTAssertEqual(leftovers(), [])
    }

    func testWhatTheCoreRefusesIsReportedByItsCodeAndTheFileIsRemoved() {
        core.refusals[0] = "city.error.busy"
        XCTAssertEqual(run.run(sessionId: "s"), .failed(code: "city.error.busy"))
        XCTAssertEqual(core.calls.map(\.n), [0])
        XCTAssertEqual(leftovers(), [])

        // Audio that cannot be read as what it is said to be: nothing is sent.
        setUp()
        core.openError = CityAudioExportError.formatMismatch
        XCTAssertEqual(run.run(sessionId: "s"), .failed(code: nil))
        XCTAssertEqual(core.calls, [])
    }

    func testOneRecordingAtATimeAndWhatWasAskedForGoesFirst() {
        var queue = CityAudioExportQueue()
        XCTAssertNil(queue.next())
        XCTAssertTrue(queue.add("a"))
        XCTAssertTrue(queue.add("b"))
        XCTAssertFalse(queue.add("a"), "already waiting")
        XCTAssertEqual(queue.next(), "a")
        XCTAssertEqual(queue.active, "a")
        XCTAssertNil(queue.next(), "one at a time")
        XCTAssertFalse(queue.add("a"), "already being filed")
        // Someone asked for this one: it goes ahead of what was waiting.
        XCTAssertTrue(queue.add("c", first: true))
        XCTAssertTrue(queue.add("d"))
        XCTAssertTrue(queue.add("d", first: true))
        queue.finish("a")
        // A recording with a request of its own in flight waits its turn.
        XCTAssertEqual(queue.next(skipping: ["d"]), "c")
        queue.finish("c")
        XCTAssertEqual(queue.next(), "d")
        queue.finish("d")
        XCTAssertEqual(queue.next(), "b")
        queue.removeAll()
        XCTAssertNil(queue.active)
        XCTAssertNil(queue.next())
    }
}

/// The audio side of a filing's status: one icon and one word beside the
/// text's, and never a word the interface cannot stand behind.
@MainActor
final class CityAudioStatusTests: XCTestCase {
    private static let languages = ["en", "th", "ja", "ko", "fr", "es", "de", "zh-Hans"]
    private let now = Date(timeIntervalSince1970: 1_794_550_000)

    private func audio(
        _ filing: FfiCityFiling,
        uploading: Bool = false,
        planned: UInt32? = nil,
        missing: Bool = false,
        unreadable: Bool = false
    ) -> CityAudioStatus {
        CityAudioStatus.resolve(
            filing,
            uploading: uploading,
            planned: planned,
            missing: missing,
            unreadable: unreadable,
            signer: "Sam",
            now: now
        )
    }

    private func filing(
        _ state: FfiCityFilingState = .filed,
        wanted: Bool = true,
        withheld: Bool = false,
        due: Bool = false,
        planned: UInt32 = 0,
        filed: UInt32 = 0,
        error: String? = nil,
        retryAt: Int64? = nil
    ) -> FfiCityFiling {
        CityAudioFixture.filing(
            state,
            wanted: wanted,
            withheld: withheld,
            due: due,
            planned: planned,
            filed: filed,
            audioError: error,
            retryAt: retryAt
        )
    }

    func testEachAudioStateOfAFiledRecordingHasItsOwnKind() {
        let later = Int64(now.timeIntervalSince1970) + 3_600
        let earlier = Int64(now.timeIntervalSince1970) - 60

        // Before the text is filed: whether the audio will go with it.
        XCTAssertEqual(audio(filing(.bound)).kind, .included)
        XCTAssertEqual(audio(filing(.queued)).kind, .included)
        XCTAssertEqual(audio(filing(.bound, wanted: false, withheld: true)).kind, .off)
        XCTAssertEqual(audio(filing(.failed, wanted: false)).kind, .off)

        // Filed, audio on its way.
        XCTAssertEqual(audio(filing(due: true)).kind, .queued)
        XCTAssertEqual(audio(filing(due: true), uploading: true).kind, .uploading)
        XCTAssertEqual(audio(filing(due: true, planned: 24, filed: 3), uploading: true).kind, .uploading)
        XCTAssertEqual(audio(filing(due: true, planned: 24, filed: 3)).kind, .queued)
        XCTAssertEqual(audio(filing(due: true, planned: 24, filed: 3, error: "city.error.offline")).kind, .queued)
        XCTAssertEqual(
            audio(filing(due: true, planned: 24, filed: 3, error: "city.error.audio_server_full")).kind,
            .queued
        )
        XCTAssertEqual(audio(filing(planned: 24, filed: 24)).kind, .filed)
        // The last part has landed while the run is still wrapping up.
        XCTAssertEqual(audio(filing(planned: 24, filed: 24), uploading: true).kind, .filed)

        // Stopped, each for its own reason.
        XCTAssertEqual(
            audio(filing(due: true, planned: 24, filed: 3, error: "city.error.audio_refused")).kind,
            .refused
        )
        XCTAssertEqual(
            audio(filing(due: true, planned: 24, filed: 3, error: "city.error.audio_too_big")).kind,
            .tooBig
        )
        XCTAssertEqual(
            audio(filing(due: true, planned: 24, filed: 3, error: "city.error.audio_daily_cap", retryAt: later)).kind,
            .capped
        )
        // Once the city's time has come it is simply queued again.
        XCTAssertEqual(
            audio(filing(due: true, planned: 24, filed: 3, error: "city.error.audio_daily_cap", retryAt: earlier)).kind,
            .queued
        )

        // Filed without audio, and nobody asked for it since: it waits for a person.
        XCTAssertEqual(audio(filing()).kind, .absent)
        // Switched off for this recording, or in Settings.
        XCTAssertEqual(audio(filing(wanted: false, withheld: true)).kind, .off)
        XCTAssertEqual(audio(filing(wanted: false)).kind, .off)
        // Switched off after some parts went: they are out there.
        XCTAssertEqual(audio(filing(wanted: false, withheld: true, planned: 24, filed: 3)).kind, .partial)

        // Nothing on this Mac to file; or it could not be prepared.
        XCTAssertEqual(audio(filing(due: true), missing: true).kind, .missing)
        XCTAssertEqual(audio(filing(due: true, planned: 24, filed: 3), missing: true).kind, .partial)
        XCTAssertEqual(audio(filing(due: true), unreadable: true).kind, .unreadable)

        // Withdrawn: what was filed stays filed.
        XCTAssertEqual(audio(filing(.withdrawn, planned: 24, filed: 24)).kind, .retained)
        XCTAssertEqual(audio(filing(.withdrawn)).kind, .included)
    }

    func testEveryAudioStateHasItsOwnWordAndItsOwnSymbol() {
        let later = Int64(now.timeIntervalSince1970) + 3_600
        let all = [
            audio(filing(.bound)),
            audio(filing(.bound, wanted: false, withheld: true)),
            audio(filing()),
            audio(filing(due: true)),
            audio(filing(due: true, planned: 24, filed: 3), uploading: true),
            audio(filing(planned: 24, filed: 24)),
            audio(filing(due: true, planned: 24, filed: 3, error: "city.error.audio_refused")),
            audio(filing(due: true, planned: 24, filed: 3, error: "city.error.audio_too_big")),
            audio(filing(due: true, planned: 24, filed: 3, error: "city.error.audio_daily_cap", retryAt: later)),
            audio(filing(due: true), missing: true),
            audio(filing(due: true), unreadable: true),
            audio(filing(.withdrawn, planned: 24, filed: 24)),
        ]
        XCTAssertEqual(Set(all.map(\.kind)).count, all.count)
        XCTAssertEqual(Set(all.map(\.label)).count, all.count)
        XCTAssertEqual(Set(all.map(\.symbol)).count, all.count)
        for one in all {
            XCTAssertFalse(one.label.isEmpty)
            XCTAssertFalse(one.label.hasPrefix("city."), "\(one.kind) shows its key")
            XCTAssertFalse(one.label.contains("%"), "\(one.kind) shows a format specifier")
            XCTAssertFalse(one.reason?.contains("%") ?? false, "\(one.kind)")
            XCTAssertFalse(one.reason?.hasPrefix("city.") ?? false, "\(one.kind)")
        }

        // "Audio 3/24" while it uploads; before the parts are counted, only that it is.
        let uploading = audio(filing(due: true, planned: 24, filed: 3), uploading: true)
        XCTAssertTrue(uploading.label.contains("3") && uploading.label.contains("24"), uploading.label)
        XCTAssertEqual(
            audio(filing(due: true), uploading: true).label,
            String(localized: "city.audio.uploading")
        )
        // The run has counted the parts before the ledger has.
        let counted = audio(filing(due: true), uploading: true, planned: 24)
        XCTAssertTrue(counted.label.contains("0") && counted.label.contains("24"), counted.label)
        // Stopped part-way: how far it got.
        let partial = audio(filing(wanted: false, withheld: true, planned: 24, filed: 3))
        XCTAssertTrue(partial.label.contains("3") && partial.label.contains("24"), partial.label)
    }

    func testRedIsOnlyForAudioThatWillNotGoByItself() {
        let later = Int64(now.timeIntervalSince1970) + 3_600
        XCTAssertEqual(audio(filing(planned: 2, filed: 2)).tone, .success)
        for code in ["city.error.audio_refused", "city.error.audio_too_big"] {
            XCTAssertEqual(audio(filing(due: true, error: code)).tone, .failure, code)
        }
        XCTAssertEqual(audio(filing(due: true), unreadable: true).tone, .failure)
        XCTAssertEqual(audio(filing(wanted: false, planned: 24, filed: 3)).tone, .warning)
        let quiet = [
            audio(filing(.bound)), audio(filing()), audio(filing(due: true)),
            audio(filing(due: true), uploading: true), audio(filing(wanted: false)),
            audio(filing(due: true, error: "city.error.audio_daily_cap", retryAt: later)),
            audio(filing(due: true, error: "city.error.offline")),
            audio(filing(due: true), missing: true),
        ]
        for one in quiet {
            XCTAssertEqual(one.tone, .quiet, "\(one.kind)")
        }
    }

    func testEachAudioStateOffersWhatAPersonCanDoAboutIt() {
        let later = Int64(now.timeIntervalSince1970) + 3_600
        // Filed before this version, or with audio off at the time: only a
        // person adds the audio.
        XCTAssertEqual(audio(filing()).action, .file)
        XCTAssertEqual(audio(filing(due: true, error: "city.error.offline")).action, .retry)
        // Merely waiting its turn: nothing to press.
        XCTAssertNil(audio(filing(due: true)).action)
        XCTAssertEqual(audio(filing(due: true, error: "city.error.audio_refused")).action, .retry)
        XCTAssertEqual(audio(filing(due: true), unreadable: true).action, .retry)
        // Nothing to press: it is going, it is done, it cannot go, or the switch is elsewhere.
        XCTAssertNil(audio(filing(due: true), uploading: true).action)
        XCTAssertNil(audio(filing(planned: 2, filed: 2)).action)
        XCTAssertNil(audio(filing(due: true, error: "city.error.audio_too_big")).action)
        XCTAssertNil(audio(filing(due: true, error: "city.error.audio_daily_cap", retryAt: later)).action)
        XCTAssertNil(audio(filing(due: true), missing: true).action)
        XCTAssertNil(audio(filing(wanted: false)).action)
        // And nothing at all while this recording has a request in flight.
        XCTAssertNil(CityAudioStatus.resolve(filing(), busy: true, now: now).action)
    }

    func testTheReasonSaysWhatHappenedAndWhatIsPublic() {
        let later = Int64(now.timeIntervalSince1970) + 3_600
        let capped = audio(filing(due: true, error: "city.error.audio_daily_cap", retryAt: later))
        // When it resumes is in the tooltip.
        XCTAssertEqual(capped.reason?.contains(CityText.moment(epoch: later)), true)
        XCTAssertEqual(
            audio(filing(due: true, error: "city.error.audio_refused")).reason,
            CityText.message(forCode: "city.error.audio_refused")
        )
        XCTAssertEqual(
            audio(filing(due: true, error: "city.error.offline")).reason,
            CityText.message(forCode: "city.error.offline")
        )
        XCTAssertEqual(audio(filing(planned: 2, filed: 2)).reason, String(localized: "city.audio.public"))
        XCTAssertEqual(audio(filing(due: true), missing: true).reason, String(localized: "city.audio.reason.missing"))
        XCTAssertEqual(
            audio(filing(wanted: false, withheld: true)).reason,
            String(localized: "city.audio.reason.withheld")
        )
        XCTAssertEqual(audio(filing(wanted: false)).reason, String(localized: "city.audio.reason.setting_off"))
        // Parts already filed are said to be out there, whatever stopped the rest.
        let partial = audio(filing(wanted: false, withheld: true, planned: 24, filed: 3))
        XCTAssertEqual(partial.reason?.contains(String(localized: "city.audio.public")), true)
        let retained = audio(filing(.withdrawn, planned: 24, filed: 24))
        XCTAssertEqual(retained.reason?.contains("24"), true)
    }

    /// Text filed and audio refused is a filed recording with a word about
    /// its audio beside it — never a failed filing.
    func testAudioNeverChangesWhatIsSaidAboutTheText() {
        let refused = filing(due: true, planned: 24, filed: 3, error: "city.error.audio_refused")
        let status = CityFilingStatus.resolve(refused, busy: false, offline: false, signer: "Sam", now: now)
        XCTAssertEqual(status.kind, .filed)
        XCTAssertEqual(status.tone, .success)
        XCTAssertEqual(status.label, String(localized: "city.word.filed"))
        XCTAssertNil(status.reason)
        XCTAssertEqual(status.audio?.kind, .refused)
        XCTAssertEqual(status.audioBeside?.kind, .refused)
        // The sentence for tooltips and VoiceOver carries both.
        let spoken = status.described(event: "Language Exchange")
        XCTAssertTrue(spoken.contains(status.label))
        XCTAssertTrue(spoken.contains(String(localized: "city.audio.refused")))
        XCTAssertTrue(status.tooltip(event: "Language Exchange").contains(
            CityText.message(forCode: "city.error.audio_refused")
        ))

        // Before the text is filed the audio word is not put beside it.
        let bound = CityFilingStatus.resolve(filing(.bound), busy: false, offline: false, now: now)
        XCTAssertEqual(bound.audio?.kind, .included)
        XCTAssertNil(bound.audioBeside)
        XCTAssertNil(CityFilingStatus.resolve(nil, busy: false, offline: false, now: now).audio)
        // Withdrawn: only what stays filed is mentioned.
        XCTAssertNil(CityFilingStatus.resolve(filing(.withdrawn), busy: false, offline: false, now: now).audioBeside)
        XCTAssertEqual(
            CityFilingStatus.resolve(filing(.withdrawn, planned: 4, filed: 4), busy: false, offline: false, now: now)
                .audioBeside?.kind,
            .retained
        )
    }

    /// The status is one word; the sentence it stood for is the hint.
    func testATextStatusIsOneWordAndKeepsItsSentenceAsTheHint() {
        let status = { (filing: FfiCityFiling?, offline: Bool) in
            CityFilingStatus.resolve(filing, busy: false, offline: offline, now: self.now)
        }
        XCTAssertEqual(status(filing(), false).hint, String(localized: "city.status.filed"))
        XCTAssertEqual(status(filing(.queued), false).label, String(localized: "city.word.waiting"))
        XCTAssertEqual(status(filing(.queued), false).hint, String(localized: "city.status.waiting"))
        XCTAssertEqual(status(filing(.queued), true).label, String(localized: "city.word.waiting_offline"))
        XCTAssertEqual(status(filing(.queued), true).hint, String(localized: "city.status.waiting_offline"))
        XCTAssertEqual(status(filing(.bound), false).hint, String(localized: "city.status.chosen"))
        // The Chinese words are at most four characters: 已交、排队、已选、没联网、活动已删.
        let chinese = NSDictionary(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources/zh-Hans.lproj/Localizable.strings")) as? [String: String]
        for key in ["city.word.chosen", "city.word.waiting", "city.word.waiting_offline",
                    "city.word.filed", "city.word.event_gone"] {
            XCTAssertLessThanOrEqual(chinese?[key]?.count ?? 99, 4, key)
        }
    }

    func testTheTallyCountsAudioThatIsGoingAndAudioThatNeedsSomeone() {
        let later = Int64(now.timeIntervalSince1970) + 3_600
        let list = [
            CityAudioFixture.filing(session: "done", planned: 2, filed: 2),
            CityAudioFixture.filing(session: "going", due: true, planned: 24, filed: 3),
            CityAudioFixture.filing(session: "queued", due: true),
            CityAudioFixture.filing(session: "capped", due: true, audioError: "city.error.audio_daily_cap", retryAt: later),
            CityAudioFixture.filing(session: "refused", due: true, audioError: "city.error.audio_refused"),
            CityAudioFixture.filing(session: "big", due: true, audioError: "city.error.audio_too_big"),
            CityAudioFixture.filing(session: "broken", due: true),
            CityAudioFixture.filing(session: "gone", due: true),
            CityAudioFixture.filing(session: "text-only"),
            CityAudioFixture.filing(.bound, session: "bound"),
        ]
        let tally = CityFilingTally.count(
            list,
            busy: [],
            audioUploading: "going",
            audioMissing: ["gone"],
            audioUnreadable: ["broken"],
            now: now
        )
        XCTAssertEqual(tally.filed, 9)
        XCTAssertEqual(tally.chosen, 1)
        XCTAssertEqual(tally.audioSending, 3)
        XCTAssertEqual(tally.audioStuck, 3)
        XCTAssertTrue(tally.needsALook)
        XCTAssertFalse(tally.summary?.contains("%") ?? true)

        // The sidebar: audio the city refused outranks what is merely on its way.
        XCTAssertEqual(tally.attention?.tone, .failure)
        XCTAssertEqual(tally.attention?.text.contains("3"), true)
        let going = CityFilingTally(filed: 2, audioSending: 1)
        XCTAssertEqual(going.attention?.tone, .quiet)
        XCTAssertFalse(going.needsALook)
        XCTAssertNil(CityFilingTally(filed: 5).attention)
        // A failed text filing still comes first.
        XCTAssertEqual(
            CityFilingTally(failed: 1, audioStuck: 2).attention?.text,
            String(format: String(localized: "city.sidebar.failed_format"), Int64(1))
        )
    }

    /// Refused and too-big audio would fail the same way again; everything
    /// else that is due is retried by itself.
    func testOnlyAudioThatCanSucceedKeepsTheRetryClockRunning() {
        XCTAssertTrue(CityStore.audioRetriesItself(filing(due: true)))
        XCTAssertTrue(CityStore.audioRetriesItself(filing(due: true, error: "city.error.offline")))
        XCTAssertTrue(CityStore.audioRetriesItself(filing(due: true, error: "city.error.audio_daily_cap")))
        XCTAssertTrue(CityStore.audioRetriesItself(filing(due: true, error: "city.error.audio_server_full")))
        XCTAssertFalse(CityStore.audioRetriesItself(filing(due: true, error: "city.error.audio_refused")))
        XCTAssertFalse(CityStore.audioRetriesItself(filing(due: true, error: "city.error.audio_too_big")))
        XCTAssertFalse(CityStore.audioRetriesItself(filing()))
        XCTAssertFalse(CityStore.audioRetriesItself(filing(planned: 2, filed: 2)))
    }

    func testAudioWordingExistsInEveryInterfaceLanguage() throws {
        let words = [
            "city.audio.off", "city.audio.included", "city.audio.absent", "city.audio.queued",
            "city.audio.uploading", "city.audio.filed", "city.audio.refused", "city.audio.too_big",
            "city.audio.capped", "city.audio.missing", "city.audio.unreadable", "city.audio.retained",
            "city.audio.file", "city.word.chosen", "city.word.waiting", "city.word.waiting_offline",
            "city.word.filed", "city.word.event_gone",
        ]
        for language in Self.languages {
            let strings = try self.strings(language)
            for key in words {
                let value = try XCTUnwrap(strings[key], "\(language) lacks \(key)")
                XCTAssertFalse(value.isEmpty, "\(language) \(key)")
                XCTAssertFalse(value.contains("%"), "\(language) \(key)")
                // A word, not a sentence.
                XCTAssertFalse(value.hasSuffix(".") || value.hasSuffix("。"), "\(language) \(key): \(value)")
                XCTAssertLessThanOrEqual(value.count, 26, "\(language) \(key): \(value)")
            }
            let progress = try XCTUnwrap(strings["city.audio.progress_format"], language)
            XCTAssertTrue(progress.contains("%1$lld") && progress.contains("%2$lld"), language)
            XCTAssertTrue(try XCTUnwrap(strings["city.audio.reason.capped_format"]).contains("%@"), language)
            XCTAssertTrue(try XCTUnwrap(strings["city.audio.reason.retained_format"]).contains("%lld"), language)
            for key in ["city.tally.audio_sending_format", "city.tally.audio_stuck_format",
                        "city.sidebar.audio_stuck_format", "city.sidebar.audio_sending_format"] {
                XCTAssertTrue(try XCTUnwrap(strings[key], "\(language) \(key)").contains("%lld"), "\(language) \(key)")
            }
        }
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }
}

/// What the interface says about audio must be true: filed audio is public
/// and cannot be deleted, and nothing in the city's screens says it stays.
@MainActor
final class CityAudioTruthTests: XCTestCase {
    private static let languages = ["en", "th", "ja", "ko", "fr", "es", "de", "zh-Hans"]

    private func strings(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// Every City*.swift in the app, by file name.
    private func citySources() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        var sources: [String: String] = [:]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.lastPathComponent.hasPrefix("City")
            && file.pathExtension == "swift" {
            sources[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
        }
        XCTAssertGreaterThan(sources.count, 15)
        return sources
    }

    func testTheSummarySaysTheAudioGoesWhenItDoesAndPromisesNothingWhenItDoesNot() {
        let on = FfiCityFilingOptions(speakerNames: true, audio: true, automatic: true)
        let off = FfiCityFilingOptions(speakerNames: false, audio: false, automatic: true)
        let audio = String(localized: "city.summary.audio_included")

        let withAudio = CityText.summary(signer: "Sam", languages: ["en", "th"], options: on, channel: "Exchange")
        XCTAssertTrue(withAudio.contains("Sam"))
        XCTAssertTrue(withAudio.contains("English"))
        XCTAssertTrue(withAudio.contains("Exchange"))
        XCTAssertTrue(withAudio.contains(String(localized: "city.summary.names")))
        XCTAssertTrue(withAudio.hasSuffix(audio))

        // Setting off: no audio sentence, and no claim about where audio stays.
        let without = CityText.summary(signer: "Sam", languages: ["en"], options: off, channel: nil)
        XCTAssertFalse(without.contains(audio))
        XCTAssertTrue(without.contains(String(localized: "city.summary.no_names")))
        XCTAssertEqual(without, CityText.whatIsFiled(signer: "Sam", languages: ["en"], options: off))
        // Setting on, this recording switched off: likewise.
        XCTAssertFalse(
            CityText.summary(signer: "Sam", languages: ["en"], options: on, channel: nil, audio: false)
                .contains(audio)
        )
        // The setting can only be reduced per recording, never raised — but
        // what the sentence says follows what it is told will happen.
        XCTAssertTrue(
            CityText.summary(signer: "Sam", languages: [], options: on, channel: nil, audio: true)
                .hasSuffix(audio)
        )
        // Marks are never filed, so they are never mentioned.
        XCTAssertFalse(withAudio.contains("标记"))
        XCTAssertFalse(withAudio.localizedCaseInsensitiveContains("marks"))
    }

    func testTheNextRecordingsAudioChoiceCanOnlyReduce() {
        typealias Choice = CityDestinationAudioChoice
        // Setting on, an event chosen: the person's to tick.
        XCTAssertEqual(
            Choice.resolve(settingOn: true, withheld: false, filing: true),
            Choice(withheld: false, canChange: true)
        )
        XCTAssertTrue(Choice.resolve(settingOn: true, withheld: false, filing: true).filesAudio)
        XCTAssertFalse(Choice.resolve(settingOn: true, withheld: true, filing: true).filesAudio)
        // Setting off: shown as ticked, and not theirs to untick here.
        XCTAssertEqual(
            Choice.resolve(settingOn: false, withheld: false, filing: true),
            Choice(withheld: true, canChange: false)
        )
        XCTAssertFalse(Choice.resolve(settingOn: false, withheld: false, filing: true).filesAudio)
        // No event: nothing is filed, so nothing to choose.
        XCTAssertFalse(Choice.resolve(settingOn: true, withheld: false, filing: false).canChange)
        XCTAssertFalse(Choice.resolve(settingOn: true, withheld: false, filing: false).filesAudio)

        // The menu ends with "No audio", under a line of its own.
        let entries = CityDestinationMenuEntry.entries(
            running: [("e1", "Open house")],
            chosen: ("e1", "Open house"),
            explicitlyNotFiling: false,
            audio: Choice(withheld: true, canChange: true)
        )
        XCTAssertEqual(
            entries,
            [
                .event(id: "e1", title: "Open house", isChosen: true),
                .separator,
                .pickFromCalendar,
                .notFiling(isChosen: false),
                .separator,
                .withholdAudio(isChosen: true, isEnabled: true),
            ]
        )
    }

    func testNoCityScreenSaysTheAudioStaysOnThisMac() throws {
        let sources = try citySources()
        // Keys whose words were true in 0.8.2 and are not any more.
        let retired = [
            "share.audio_never", "city.summary.audio_stays", "city.what.never",
            "city.signin.trust", "city.withdraw.confirm_message", "city.summary.extras",
        ]
        for (name, source) in sources {
            let code = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
            for key in retired {
                XCTAssertFalse(code.contains("\"\(key)"), "\(name) still uses \(key)")
            }
        }

        // Every `city.` string a city screen can show, in Chinese and English.
        let pattern = try NSRegularExpression(pattern: "\"((?:city|home)\\.[a-z0-9_.]+)\"")
        var keys = Set<String>()
        for source in sources.values {
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                keys.insert(String(source[Range(match.range(at: 1), in: source)!]))
            }
        }
        XCTAssertGreaterThan(keys.count, 120)
        let chinese = try strings("zh-Hans")
        let english = try strings("en")
        for key in keys {
            let zh = chinese[key] ?? ""
            let en = english[key] ?? ""
            for claim in ["留在这台 Mac", "不离开这台 Mac", "从不离开", "音频不交", "只交文字"] {
                XCTAssertFalse(zh.contains(claim), "\(key): \(zh)")
            }
            for claim in ["stays on this Mac", "never leaves", "audio stays", "audio is never", "text only"] {
                XCTAssertFalse(en.localizedCaseInsensitiveContains(claim), "\(key): \(en)")
            }
        }
    }

    func testWhatMustBeReadableSaysPublicAndCannotBeDeletedInEveryLanguage() throws {
        let disclosures = [
            "city.signin.disclosure", "city.audio.disclosure", "city.audio.public",
            "city.summary.audio_included", "city.withdraw.confirm_one", "city.signout.confirm_one",
            "city.share.public_note",
        ]
        for language in Self.languages {
            let strings = try self.strings(language)
            for key in disclosures {
                let value = try XCTUnwrap(strings[key], "\(language) lacks \(key)")
                XCTAssertGreaterThan(value.count, 12, "\(language) \(key)")
                XCTAssertFalse(value.contains("%"), "\(language) \(key)")
            }
        }
        let chinese = try strings("zh-Hans")
        let english = try strings("en")
        for key in ["city.signin.disclosure", "city.audio.disclosure", "city.audio.public",
                    "city.summary.audio_included"] {
            let zh = try XCTUnwrap(chinese[key])
            let en = try XCTUnwrap(english[key])
            XCTAssertTrue(zh.contains("公开") && zh.contains("删不掉"), "\(key): \(zh)")
            XCTAssertTrue(en.contains("public") && en.contains("can’t be deleted"), "\(key): \(en)")
            XCTAssertTrue(zh.contains("音频"), "\(key): \(zh)")
            XCTAssertTrue(en.localizedCaseInsensitiveContains("audio"), "\(key): \(en)")
        }
        // Signing in: this Mac acts as you; audio goes by default.
        XCTAssertTrue(try XCTUnwrap(chinese["city.signin.disclosure"]).contains("以你的名义"))
        XCTAssertTrue(try XCTUnwrap(chinese["city.signin.disclosure"]).contains("默认"))
        XCTAssertTrue(try XCTUnwrap(english["city.signin.disclosure"]).contains("by default"))
        // The city's hosts can have filed audio transcribed again.
        XCTAssertTrue(try XCTUnwrap(chinese["city.audio.disclosure"]).contains("转写"))
        XCTAssertTrue(try XCTUnwrap(english["city.audio.disclosure"]).contains("transcribed again"))
        // Withdrawing: one sentence; the page stops showing it, text and audio stay.
        let withdrawZh = try XCTUnwrap(chinese["city.withdraw.confirm_one"])
        let withdrawEn = try XCTUnwrap(english["city.withdraw.confirm_one"])
        XCTAssertTrue(withdrawZh.contains("文字") && withdrawZh.contains("音频") && withdrawZh.contains("留在"))
        XCTAssertTrue(withdrawEn.contains("text and audio") && withdrawEn.contains("stay"))
        XCTAssertEqual(withdrawZh.filter { $0 == "。" }.count, 1)
        XCTAssertEqual(withdrawEn.filter { $0 == "." }.count, 1)
        XCTAssertEqual(CityText.withdrawConfirmation, String(localized: "city.withdraw.confirm_one"))
        XCTAssertEqual(CityText.signInDisclosure, String(localized: "city.signin.disclosure"))
        XCTAssertEqual(CityText.audioDisclosure, String(localized: "city.audio.disclosure"))
    }
}

private final class CityAudioSilentCallback: FfiNotebookCaptureCallback, @unchecked Sendable {
    func onCaptureEvent(event: FfiNotebookCaptureEvent) {}
    func onLivePreview(preview: FfiNotebookCaptureLivePreview) {}
}

/// The exporter against audio the real core stored: that milliseconds on the
/// recording's own timeline are where the sound is, across the one-minute
/// chunks audio is stored in, and that a pause adds nothing to that timeline.
final class CityAudioExportCoreTests: XCTestCase {
    private var core: ZuTalkCore!
    private var dataDir: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zutalk-city-audio-\(UUID().uuidString)", isDirectory: true)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zutalk-city-audio-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        core = try ZuTalkCore.newDeferred(dataDir: dataDir.path)
    }

    override func tearDown() {
        try? core.shutdown()
        try? FileManager.default.removeItem(at: dataDir)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// 16-bit mono PCM with a tone during each of `beeps` (in seconds).
    private func pcm16(seconds: Int, rate: Int, beeps: [Range<Double>]) -> Data {
        var samples = [Int16](repeating: 0, count: seconds * rate)
        for beep in beeps {
            for frame in Int(beep.lowerBound * Double(rate))..<Int(beep.upperBound * Double(rate)) {
                samples[frame] = Int16(sin(2 * Double.pi * 440 * Double(frame) / Double(rate)) * 16_000)
            }
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func wav(_ pcm: Data, rate: Int) throws -> URL {
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        let url = scratch.appendingPathComponent("recording.wav")
        try (header + pcm).write(to: url)
        return url
    }

    func testAnImportedRecordingIsExportedOnItsOwnTimelineAcrossMinuteChunks() throws {
        // 130 seconds of silence with a beep at 61–62 s and at 125–126 s:
        // one just past the first minute chunk's end, one in the third chunk.
        let source = try wav(pcm16(seconds: 130, rate: 16_000, beeps: [61..<62, 125..<126]), rate: 16_000)
        let notebook = try core.createNotebook(title: "Archive audio")
        let sessionId = try core.importAudioIntoNotebook(path: source.path, notebookId: notebook.id).sessionId

        let reader = CityAudioExportCore(core: core)
        let recording = try XCTUnwrap(try reader.open(sessionId: sessionId))
        XCTAssertEqual(recording.format, CityAudioExportFormat(sampleRate: 16_000, channels: 1))
        XCTAssertEqual(recording.durationMs, 130_000)

        // Fifty-second parts, so that parts straddle the chunk seams at 60 s and 120 s.
        let parts = CityAudioExport.parts(durationMs: recording.durationMs, partMs: 50_000, filed: [])
        XCTAssertEqual(parts.map(\.t0Ms), [0, 50_000, 100_000])
        XCTAssertEqual(parts.map(\.durMs), [50_000, 50_000, 30_000])
        let plan = CityAudioFixture.plan(partMs: 50_000)

        let first = try CityAudioExport.export(parts[0], from: recording, cityAudioPlan: plan, into: scratch)
        XCTAssertEqual(first.levels, String(repeating: "0", count: 50))

        // [50 s, 100 s): the beep at 61 s is this part's twelfth second.
        let second = try CityAudioExport.export(parts[1], from: recording, cityAudioPlan: plan, into: scratch)
        XCTAssertEqual(second.paddedFrames, 0)
        var expected = [Character](repeating: "0", count: 50)
        expected[11] = "9"
        XCTAssertEqual(second.levels, String(expected))
        let decoded = try CityAudioFixture.decode(second.url)
        XCTAssertEqual(Double(decoded.samples.count) / decoded.rate, 50, accuracy: 0.15)
        XCTAssertGreaterThan(CityAudioFixture.rms(decoded.samples, from: 11.2, to: 11.8, rate: decoded.rate), 0.2)
        XCTAssertLessThan(CityAudioFixture.rms(decoded.samples, from: 9.5, to: 10.8, rate: decoded.rate), 0.02)
        XCTAssertLessThan(CityAudioFixture.rms(decoded.samples, from: 12.2, to: 13.5, rate: decoded.rate), 0.02)

        // [100 s, 130 s): the beep at 125 s is its twenty-sixth second.
        let third = try CityAudioExport.export(parts[2], from: recording, cityAudioPlan: plan, into: scratch)
        XCTAssertEqual(third.paddedFrames, 0)
        expected = [Character](repeating: "0", count: 30)
        expected[25] = "9"
        XCTAssertEqual(third.levels, String(expected))
    }

    func testAudioThatWasDestroyedIsSimplyNotThere() throws {
        let source = try wav(pcm16(seconds: 3, rate: 16_000, beeps: [1..<2]), rate: 16_000)
        let notebook = try core.createNotebook(title: "Archive audio")
        let sessionId = try core.importAudioIntoNotebook(path: source.path, notebookId: notebook.id).sessionId
        let reader = CityAudioExportCore(core: core)
        XCTAssertNotNil(try reader.open(sessionId: sessionId))

        try core.destroySessionAudioAndKey(sessionId: sessionId)

        XCTAssertNil(try reader.open(sessionId: sessionId))
        // And the run reports it as a state, having sent nothing.
        let filing = FakeCityAudioCore()
        let outcome = CityAudioExportRun(filing: filing, audio: reader, directory: scratch).run(sessionId: sessionId)
        XCTAssertEqual(outcome, .noAudio)
        XCTAssertEqual(filing.calls, [])
    }

    /// A paused recording: what is pushed is the timeline. The pause, however
    /// long on the wall clock, is not on it — the same clock the core gives
    /// the transcript's sentences.
    func testAPauseAddsNothingToTheTimelineOfARecordedSession() throws {
        let notebook = try core.createNotebook(title: "Archive audio")
        var profile = try core.getNotebookCaptureProfile(notebookId: notebook.id)
        profile.remoteRealtimeEnabled = false
        profile.privacyLevel = "standard"
        profile = try core.updateNotebookCaptureProfile(profile: profile)
        let started = try core.startNotebookCaptureSession(
            notebookId: notebook.id,
            profileRevision: profile.revision,
            confirmedContextDigest: nil,
            callback: CityAudioSilentCallback()
        )
        let sessionId = started.sessionId

        // Three seconds with a beep in the second one; a pause; two more
        // seconds with a beep in the first of them.
        try core.pushNotebookCaptureSession(
            sessionId: sessionId,
            audioData: pcm16(seconds: 3, rate: 16_000, beeps: [1..<2])
        )
        _ = try core.pauseNotebookCaptureSession(sessionId: sessionId, paused: true)
        // Audio pushed while paused is not accepted: nothing joins the timeline.
        XCTAssertThrowsError(
            try core.pushNotebookCaptureSession(
                sessionId: sessionId,
                audioData: pcm16(seconds: 1, rate: 16_000, beeps: [0..<1])
            )
        )
        Thread.sleep(forTimeInterval: 1.2)
        _ = try core.pauseNotebookCaptureSession(sessionId: sessionId, paused: false)
        try core.pushNotebookCaptureSession(
            sessionId: sessionId,
            audioData: pcm16(seconds: 2, rate: 16_000, beeps: [0..<1])
        )
        _ = try core.stopNotebookCaptureSession(sessionId: sessionId)

        let recording = try XCTUnwrap(try CityAudioExportCore(core: core).open(sessionId: sessionId))
        XCTAssertEqual(recording.format, CityAudioExportFormat(sampleRate: 16_000, channels: 1))
        // Five seconds were pushed; the 1.2 s pause is nowhere.
        XCTAssertEqual(recording.durationMs, 5_000)
        let exported = try CityAudioExport.export(
            CityAudioExportPart(n: 0, t0Ms: 0, durMs: recording.durationMs),
            from: recording,
            cityAudioPlan: CityAudioFixture.plan(),
            into: scratch
        )
        XCTAssertEqual(exported.levels, "09090")
    }
}
