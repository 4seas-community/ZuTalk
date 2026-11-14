// CityAudioExportRun.swift
// 把一场录音的音频一段段交到城的档案馆:问 core 能不能交 → 量一量这台 Mac 上
// 还有多少音频 → 没交的每一段:导出、算音量、交、删临时文件。
//
// 规矩(docs/architecture/city-archive.md 第 3、5、6 节):
//   - 先问 `cityAudioPlan`,它说不交就一帧都不读;每一段之前再问一遍 ——
//     设置里的开关、这一场的开关,上一段到这一段之间可能被人关掉;
//   - 一场录音在第一个音频错误上停下(没连上、城不收、太大、今天放得太多、
//     服务器满了),原因写在给回的那一份记录上,由界面照实说;
//   - 这台 Mac 上已经没有音频(保留期到了、人删了音频、录音进了回收站):
//     没有可交的,是一种状态,不是出错;
//   - 临时文件交完一段删一段,没交成也删。重新导出的字节不必和上一次相同,
//     core 认得出来,所以不留文件等下次。
//
// 它自己不开线程、不碰界面:`CityStore` 在后台任务里调 `run`,进度靠回调。
// 交音频的入口(`cityFileAudioPart`)全 App 只在这里调。

import Foundation

/// 交音频要问 core 的两件事。口子收得这么窄,停下和接着交的规矩才能拿假的
/// 来测。
nonisolated protocol CityAudioExportFiling: Sendable {
    func cityAudioPlan(sessionId: String) -> FfiCityAudioPlan
    func cityFileAudioPart(
        sessionId: String,
        n: UInt32,
        total: UInt32,
        path: String,
        t0Ms: Int64,
        durMs: Int64,
        levels: String
    ) throws -> FfiCityFiling
}

/// 一场录音的音频从哪读。
nonisolated protocol CityAudioExportReading: Sendable {
    /// 这场录音存在这台 Mac 上的音频;已经没有了就是 nil。
    func open(sessionId: String) throws -> CityAudioExportRecording?
}

/// 一场录音这一趟交到哪了。
nonisolated enum CityAudioExportOutcome: Equatable, Sendable {
    /// 每一段都在城的服务器上了。这一趟一段都没发(早就交完了)时不带记录。
    case finished(FfiCityFiling?)
    /// 停在了某一段:原因在这份记录的 `audioErrorCode` 里。
    case stopped(FfiCityFiling)
    /// core 说现在不交:没登录、文字还没交、设置关着、这一场单独关了、今天
    /// 放得太多还没到点。
    case held(code: String?)
    /// 这台 Mac 上已经没有这场录音的音频。
    case noAudio
    /// 两段之间被叫停了(这场录音有别的事要先做,或者退出登录了)。
    case interrupted
    /// 这一头没办成:导出没成,或者 core 没让交。`code` 是 core 给的稳定代码。
    case failed(code: String?)
}

nonisolated struct CityAudioExportRun: Sendable {
    let filing: any CityAudioExportFiling
    let audio: any CityAudioExportReading
    var directory: URL = CityAudioExport.temporaryDirectory

    /// 交一场录音还没交的每一段。会联网、会读盘、会编码,一段可能要好几分钟:
    /// 在后台线程上调。
    ///
    /// - Parameters:
    ///   - shouldStop: 两段之间问一次;说停就停,已经交了的留着。
    ///   - began: 量出一共几段以后说一声。
    ///   - progress: 每交完一段(或者这一段没交成)给一份最新的记录。
    func run(
        sessionId: String,
        shouldStop: () -> Bool = { false },
        began: (_ total: UInt32) -> Void = { _ in },
        progress: (FfiCityFiling) -> Void = { _ in }
    ) -> CityAudioExportOutcome {
        let first = filing.cityAudioPlan(sessionId: sessionId)
        guard first.upload, first.partMs > 0 else { return .held(code: first.holdCode) }

        let opened: CityAudioExportRecording?
        do {
            opened = try audio.open(sessionId: sessionId)
        } catch {
            return .failed(code: Self.code(of: error))
        }
        guard let recording = opened, recording.durationMs > 0 else { return .noAudio }

        let total = CityAudioExport.partCount(durationMs: recording.durationMs, partMs: first.partMs)
        began(total)
        var last: FfiCityFiling?
        let waiting = CityAudioExport.parts(
            durationMs: recording.durationMs,
            partMs: first.partMs,
            filed: first.partsFiled
        )
        for part in waiting {
            if shouldStop() { return .interrupted }
            // 上一段到这一段之间,设置或这一场的开关可能改过。
            let plan = filing.cityAudioPlan(sessionId: sessionId)
            guard plan.upload else { return .held(code: plan.holdCode) }
            if plan.partsFiled.contains(part.n) { continue }

            let exported: CityAudioExportedPart
            do {
                exported = try CityAudioExport.export(
                    part,
                    from: recording,
                    cityAudioPlan: plan,
                    into: directory
                )
            } catch CityAudioExportError.nothingToRead {
                return .noAudio
            } catch {
                return .failed(code: nil)
            }
            defer { exported.discard() }

            // 这一段里有读不到、补了静音的地方:看一眼是不是音频正在被删。
            // 是的话不拿这半段去交。
            if exported.paddedFrames > 0, (try? audio.open(sessionId: sessionId)) == nil {
                return .noAudio
            }

            let result: FfiCityFiling
            do {
                result = try filing.cityFileAudioPart(
                    sessionId: sessionId,
                    n: part.n,
                    total: total,
                    path: exported.url.path,
                    t0Ms: part.t0Ms,
                    durMs: part.durMs,
                    levels: exported.levels
                )
            } catch {
                return .failed(code: Self.code(of: error))
            }
            progress(result)
            if result.audioErrorCode != nil { return .stopped(result) }
            last = result
        }
        return .finished(last)
    }

    /// core 抛出的错误里的那句话(城的错误就是稳定代码)。
    static func code(of error: Error) -> String? {
        guard let core = error as? CoreError else { return nil }
        switch core {
        case .InitFailed(let message), .ValidationFailed(let message),
             .NotFound(let message), .InternalError(let message):
            return message
        @unknown default:
            return nil
        }
    }
}

/// 等着交音频的录音。一次只交一场:导出要读盘、编码,上传占着会场本来就
/// 不宽的网,几场一起来只会都慢。
nonisolated struct CityAudioExportQueue: Equatable, Sendable {
    private(set) var waiting: [String] = []
    /// 正在交的那一场。
    private(set) var active: String?

    /// 排上。已经在排的、正在交的不排第二遍。`first`:人开口要的排到最前。
    @discardableResult
    mutating func add(_ sessionId: String, first: Bool = false) -> Bool {
        guard active != sessionId else { return false }
        if let at = waiting.firstIndex(of: sessionId) {
            guard first, at > 0 else { return false }
            waiting.remove(at: at)
            waiting.insert(sessionId, at: 0)
            return true
        }
        if first {
            waiting.insert(sessionId, at: 0)
        } else {
            waiting.append(sessionId)
        }
        return true
    }

    /// 取下一场来交。手上那一场还没完就不取;`busy` 里的(这一场正有别的
    /// 请求在路上)先留在队里。
    mutating func next(skipping busy: Set<String> = []) -> String? {
        guard active == nil,
              let at = waiting.firstIndex(where: { busy.contains($0) == false })
        else { return nil }
        active = waiting.remove(at: at)
        return active
    }

    /// 这一场这一趟完了(交完、停下、被叫停都算)。
    mutating func finish(_ sessionId: String) {
        if active == sessionId { active = nil }
    }

    mutating func removeAll() {
        waiting = []
        active = nil
    }
}

/// 真的那一个:问 core、读 core 里存的音频。
nonisolated struct CityAudioExportCore: CityAudioExportFiling, CityAudioExportReading {
    let core: any ZuTalkCoreProtocol

    func cityAudioPlan(sessionId: String) -> FfiCityAudioPlan {
        core.cityAudioPlan(sessionId: sessionId)
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
        try core.cityFileAudioPart(
            sessionId: sessionId,
            n: n,
            total: total,
            path: path,
            t0Ms: t0Ms,
            durMs: durMs,
            levels: levels
        )
    }

    func open(sessionId: String) throws -> CityAudioExportRecording? {
        let info = try core.getSession(id: sessionId)
        // 音频销毁了(保留期到了、人删了)、或者录音进了回收站:没有可交的。
        guard info.hasEncryptedAudio, info.isTrashed == false else { return nil }

        // 采样率和声道数记在这场录音的那一次录制上。录制找不到时,现场录的
        // 一律是 16 kHz 单声道(core 读音频时用的也是这个默认);导入的文件
        // 什么采样率都有,猜不得。
        let run = captureRun(sessionId: sessionId)
        guard run != nil || info.sessionType != "import" else {
            throw CityAudioExportError.formatMismatch
        }
        let format = CityAudioExportFormat(
            sampleRate: Int(run?.sampleRate ?? 16_000),
            channels: Int(run?.channels ?? 1)
        )
        let core = self.core
        let read: @Sendable (Int64, Int64) -> Data = { startMs, endMs in
            guard startMs >= 0, endMs > startMs else { return Data() }
            let segment = try? core.getAudioSegment(
                sessionId: sessionId,
                startMs: UInt64(startMs),
                endMs: UInt64(endMs)
            )
            return segment ?? Data()
        }
        var hintMs = Int64(clamping: info.durationMs)
        if let run, run.capturedFrames > 0, format.sampleRate > 0 {
            hintMs = Int64(clamping: run.capturedFrames) * 1_000 / Int64(format.sampleRate)
        }
        let durationMs = try CityAudioExport.measure(hintMs: hintMs, format: format, read: read)
        guard durationMs > 0 else { return nil }
        guard CityAudioExport.plausible(
            measuredMs: durationMs,
            recordedMs: Int64(clamping: info.durationMs)
        ) else {
            throw CityAudioExportError.formatMismatch
        }
        return CityAudioExportRecording(format: format, durationMs: durationMs, read: read)
    }

    /// 这场录音的那一次录制。录音不记自己在哪个主题里,所以一个个主题找;
    /// 只读本机,一场录音交音频之前找一次。
    private func captureRun(sessionId: String) -> FfiNotebookCaptureHistoryRun? {
        var notebooks = (try? core.listNotebooks()) ?? []
        if let quick = try? core.getQuickCaptureNotebook(),
           notebooks.contains(where: { $0.id == quick.id }) == false {
            notebooks.append(quick)
        }
        for notebook in notebooks {
            let runs = (try? core.listNotebookCaptureHistorySummaries(notebookId: notebook.id)) ?? []
            if let run = runs.first(where: { $0.sessionId == sessionId }) {
                return run
            }
        }
        return nil
    }
}
