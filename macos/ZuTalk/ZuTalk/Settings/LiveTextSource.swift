// LiveTextSource.swift
// 现在靠什么出字:邀请码、自己的密钥,还是什么都没有。
//
// 「设置 › 账号」的「转录和翻译」和首次使用的第二步都要说这一句。说法只有
// 一处,判断也只有一处;判断是纯函数,可以单独测。句子里不出现供应商的名字:
// 用邀请码的人不需要知道背后是谁,用自己密钥的人去「高级」看。

import Foundation

enum LiveTextSource: Equatable {
    /// 邀请码在用。`recordableSeconds` 是按下一场录音要开的连接数折算过的
    /// 「还能录多久」;邀请服务还没答的时候是 nil。
    case invite(recordableSeconds: Int?)
    /// 邀请码的时间用完了,也没有自己的密钥可以接上。
    case inviteSpent
    case ownKey
    case nothing

    /// 和开始录音时的顺序一样(`CommunityInviteSession.prepareRealtimeCredential`):
    /// 邀请码开着就先用它;它用不了、而这台 Mac 上有自己的密钥时,录音会落到
    /// 自己的密钥上。
    @MainActor
    static func resolve(
        inviteActive: Bool,
        inviteEnabled: Bool,
        remainingSeconds: Int?,
        laneCount: Int,
        hasOwnKey: Bool
    ) -> LiveTextSource {
        guard inviteActive, inviteEnabled else {
            return hasOwnKey ? .ownKey : .nothing
        }
        guard let remainingSeconds else {
            return .invite(recordableSeconds: nil)
        }
        guard remainingSeconds > 0 else {
            return hasOwnKey ? .ownKey : .inviteSpent
        }
        // 邀请时长按连接数扣,侧栏一直是这么折算的;这里用同一个算法,两处
        // 不会报出两个数。
        return .invite(recordableSeconds: CommunityInviteSession.wallClockRecordableSeconds(
            remainingSeconds: remainingSeconds,
            laneCount: laneCount
        ))
    }

    /// 此刻的答案。「自己的密钥」看的是核心里有没有载入,和录音开始时看的是
    /// 同一个地方(`CaptureCommandCenter.realtimeCredentialAvailable`);存着
    /// 但没载入的密钥出不了字,不算。
    @MainActor
    static func current(
        invite: CommunityInviteSession? = nil,
        credentials: (any ProviderCredentialSessioning)? = nil
    ) -> LiveTextSource {
        let invite = invite ?? CommunityInviteSession.shared
        let credentials = credentials ?? ProviderCredentialSession.shared
        return resolve(
            inviteActive: invite.isActive,
            inviteEnabled: invite.isEnabled,
            remainingSeconds: invite.remainingSeconds,
            laneCount: invite.plannedLaneCount,
            hasOwnKey: credentials.snapshot().contains { $0.account == .soniox && $0.isActive }
        )
    }

    /// 下一场录音出不出得了字。
    var powersLiveText: Bool {
        switch self {
        case .invite, .ownKey: return true
        case .inviteSpent, .nothing: return false
        }
    }

    /// 那一句话。
    var sentence: String {
        switch self {
        case .invite(let recordableSeconds?):
            let seconds = max(0, recordableSeconds)
            return String(
                format: String(localized: "settings.live_text.source.invite_time_format"),
                Int64(seconds / 3_600),
                Int64((seconds % 3_600) / 60)
            )
        case .invite(nil):
            return String(localized: "settings.live_text.source.invite")
        case .inviteSpent:
            return String(localized: "settings.live_text.source.invite_spent")
        case .ownKey:
            return String(localized: "settings.live_text.source.own_key")
        case .nothing:
            return String(localized: "settings.live_text.source.nothing")
        }
    }

    var symbol: String {
        switch self {
        case .invite: return "gift.fill"
        case .inviteSpent: return "hourglass"
        case .ownKey: return "key.fill"
        case .nothing: return "mic"
        }
    }
}
