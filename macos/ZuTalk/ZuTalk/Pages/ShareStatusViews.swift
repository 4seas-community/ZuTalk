// ShareStatusViews.swift
// 直播在菜单栏与录音药丸上的状态。主窗口里的状态在录音条的「直播」按钮上。
//
// App 缩在菜单栏里录音时,菜单栏面板是唯一看得见的表面;药丸不接鼠标,
// 只给被动指示。两处都要让主持人知道:这场录音的字幕此刻正在离开这台 Mac。

import SwiftUI

/// 菜单栏录音面板里的一行:这场录音是不是正在直播、几个人在看。
struct LiveShareStatusLabel: View {
    let sessionId: String?
    @ObservedObject private var share = ShareActivityStore.shared

    var body: some View {
        if share.isBroadcasting(sessionId: sessionId) {
            Label(LiveShareText.status(viewers: share.live?.viewers ?? 0), systemImage: "dot.radiowaves.left.and.right")
                .font(.bodySM)
                .foregroundColor(.signalGreen)
                .accessibilityIdentifier("menubar.share-live")
        }
    }
}

/// 录音药丸上的一粒电波:此刻这场录音的字幕在离开这台机器。
struct ShareBroadcastGlyph: View {
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var share = ShareActivityStore.shared

    var body: some View {
        if share.isBroadcasting(sessionId: capture.sessionId) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.signalGreen)
                .help(String(localized: "share.live.on"))
                .accessibilityLabel(String(localized: "share.live.on"))
        }
    }
}
