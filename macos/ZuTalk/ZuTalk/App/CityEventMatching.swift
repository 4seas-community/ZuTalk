// CityEventMatching.swift
// 哪场活动算「现在正在进行」。
//
// 「开始录音」页据此决定替不替人选好活动：只有一场在进行就选好，主办直接按
// 开始；有好几场就列出来让人挑（docs/architecture/city-archive.md 第 2 节）。
// 规则单独放在这里，不掺在界面里：它是一条产品判断，要能单独测、单独改。

import Foundation

enum CityEventMatching {
    /// 此刻正在进行的活动，最该排在前面的在前。
    ///
    /// 城里的活动有几样真实情况要顾到：
    /// - 人常常提早几分钟开录，活动也常常拖堂；
    /// - 同一时段不同房间会有两三场；
    /// - 有的「活动」是一整季的总场（2026 年 11 月有一场连续 49 天），它每天都
    ///   「正在进行」，会让「只有一场」永远不成立。
    static func runningNow(_ events: [FfiCityEvent], now: Date) -> [FfiCityEvent] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var running: [FfiCityEvent] = []
        for event in events {
            let length = sessionLength(of: event)
            // 总场不算：它天天都在，替人选它等于替人乱选。要归到它，从日历里选。
            if length > longestSessionMs {
                continue
            }
            let opens = event.startMs - leadInMs
            let closes = event.startMs + length + overrunMs
            if nowMs >= opens && nowMs <= closes {
                running.append(event)
            }
        }
        running.sort { lhs, rhs in
            // 自己主办或记录的在前；其次是刚开始的；再其次是短的。
            if lhs.mine != rhs.mine {
                return lhs.mine
            }
            if lhs.startMs != rhs.startMs {
                return lhs.startMs > rhs.startMs
            }
            return sessionLength(of: lhs) < sessionLength(of: rhs)
        }
        return running
    }

    /// 开场前这么久就算：人常常提早开录。
    static let leadInMs: Int64 = 15 * 60 * 1000
    /// 散场后这么久还算：活动常常拖堂。
    static let overrunMs: Int64 = 20 * 60 * 1000
    /// 比这还长的是总场，不是一场。
    static let longestSessionMs: Int64 = 12 * 60 * 60 * 1000
    /// 没写结束时刻的按这么长算。
    static let assumedLengthMs: Int64 = 2 * 60 * 60 * 1000

    private static func sessionLength(of event: FfiCityEvent) -> Int64 {
        let length = event.endMs - event.startMs
        return length > 0 ? length : assumedLengthMs
    }

    /// 只有一场在进行时替人选好；一场都没有、或有好几场，都不选。
    static func automaticChoice(_ events: [FfiCityEvent], now: Date) -> FfiCityEvent? {
        let running = runningNow(events, now: now)
        return running.count == 1 ? running[0] : nil
    }

    /// 事后补归：和这场录音时间重合的活动，重合得多的在前。
    static func overlapping(
        _ events: [FfiCityEvent],
        recordingStart: Date,
        duration: TimeInterval
    ) -> [FfiCityEvent] {
        let startMs = Int64(recordingStart.timeIntervalSince1970 * 1000)
        let endMs = startMs + Int64(max(duration, 0) * 1000)
        var scored: [(event: FfiCityEvent, overlap: Int64)] = []
        for event in events {
            let overlap = min(event.endMs, endMs) - max(event.startMs, startMs)
            if overlap > 0 {
                scored.append((event, overlap))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.overlap != rhs.overlap {
                return lhs.overlap > rhs.overlap
            }
            return lhs.event.startMs > rhs.event.startMs
        }
        return scored.map(\.event)
    }
}
