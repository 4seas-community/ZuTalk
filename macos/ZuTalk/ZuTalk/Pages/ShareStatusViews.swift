// ShareStatusViews.swift
// 共享在主窗口、菜单栏、录音药丸上的状态:正在看谁的直播、正在共享
// 什么、有人在敲门。
//
// 这些以前只在分享页上看得见:在看直播的人切到别的页面,就不知道自己
// 还连着;主持人在录音页上,听不见有人敲门(一分钟就超时)。现在它们
// 和录音条同一个位置 —— 顶栏右侧,任何页面都在。

import SwiftUI

/// 顶栏右侧、录音条左边:看别人的直播,或正在共享一段录好的录音。
/// 直播自己录的这一场时,状态在录音条的「直播」按钮上,这里不重复。
struct ShareHeaderStatus: View {
    var compact = false
    @ObservedObject private var share = ShareActivityStore.shared
    @ObservedObject private var subtitleOverlay = SubtitleOverlayCoordinator.shared

    var body: some View {
        if share.isViewing {
            watching
        } else if share.isHosting, share.isLive == false {
            hostingRecording
        }
    }

    // MARK: 看别人的

    private var watching: some View {
        HStack(spacing: Spacing.xs) {
            Button {
                MainNavigationStore.shared.select(tab: .share)
            } label: {
                HStack(spacing: Spacing.sm) {
                    if share.hostLeft || share.removedByHost {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(.textTertiary)
                    } else {
                        PulsingDot(color: .signalGreen, size: 8)
                            .accessibilityHidden(true)
                    }
                    if compact == false {
                        Text(watchingText)
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: 260, alignment: .leading)
                    }
                }
                .padding(.horizontal, Spacing.sm + 2)
                .frame(minHeight: 30)
                .background(Color.signalGreen.opacity(share.hostLeft ? 0.03 : 0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(watchingText)
            .accessibilityLabel(Text(watchingText))
            .accessibilityIdentifier("header.watching")

            if share.isLive, share.hostLeft == false, share.removedByHost == false {
                pill(
                    title: String(localized: "share.watch.subtitle_window"),
                    systemImage: subtitleOverlay.isPresented ? "pip.exit" : "pip.enter"
                ) {
                    WindowCommandRouter.shared.requestToggleSubtitleOverlay()
                }
            }
            pill(
                title: String(localized: share.hostLeft || share.removedByHost
                    ? "share.watch.close"
                    : "share.watch.leave"),
                systemImage: "xmark"
            ) {
                share.leave()
            }
            .accessibilityIdentifier("header.watching.leave")
        }
    }

    private var watchingText: String {
        let host = share.hostDisplayName
        if share.removedByHost {
            return String(format: String(localized: "share.watch.removed_format"), host)
        }
        if share.hostLeft {
            return String(format: String(localized: "share.watch.ended_format"), host)
        }
        if share.isLive {
            return String(format: String(localized: "share.watch.live_format"), host)
        }
        return String(
            format: String(localized: "share.watch.recording_format"),
            host,
            share.title.isEmpty ? String(localized: "share.untitled") : share.title
        )
    }

    // MARK: 共享录好的录音

    private var hostingRecording: some View {
        Button {
            if let sessionId = share.scopeSessionId {
                share.presentRecordingShare(sessionId: sessionId, title: share.title)
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                PulsingDot(color: .signalGreen, size: 8)
                    .accessibilityHidden(true)
                if compact == false {
                    Text(hostingText)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                if share.pendingJoinRequests.isEmpty == false || share.pendingCorrections.isEmpty == false {
                    Circle()
                        .fill(Color.signalAmber)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Spacing.sm + 2)
            .frame(minHeight: 30)
            .background(Color.signalGreen.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(hostingText)
        .accessibilityLabel(Text(hostingText))
        .accessibilityIdentifier("header.hosting")
    }

    private var hostingText: String {
        let title = share.title.isEmpty ? String(localized: "share.untitled") : share.title
        let base = share.watchers.isEmpty
            ? String(format: String(localized: "share.hosting_format"), title)
            : String(
                format: String(localized: "share.hosting_count_format"),
                title,
                Int64(share.watchers.count)
            )
        guard share.pendingCorrections.isEmpty == false else { return base }
        return base + " · " + String(
            format: String(localized: "share.corrections.count_format"),
            Int64(share.pendingCorrections.count)
        )
    }

    private func pill(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if compact {
                    Image(systemName: systemImage)
                        .frame(width: 30, height: 30)
                } else {
                    Label(title, systemImage: systemImage)
                        .padding(.horizontal, Spacing.sm + 2)
                        .frame(minHeight: 30)
                }
            }
            .font(.bodyMedium)
            .foregroundColor(.textPrimary)
            .background(Color.textPrimary.opacity(0.08))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(Text(title))
    }
}

/// 顶栏下方一整行:有人想加入。在任何页面都能当场回答。
struct JoinRequestBanner: View {
    @ObservedObject private var share = ShareActivityStore.shared

    var body: some View {
        if share.isHosting, share.pendingJoinRequests.isEmpty == false {
            JoinRequestList()
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)
                .accessibilityIdentifier("header.join-requests")
        }
    }
}

/// 菜单栏录音面板里的一行:这场录音是不是正在直播、几个人在看。
/// App 缩在菜单栏里录音时,这里是唯一看得见的表面。
struct LiveShareStatusLabel: View {
    let sessionId: String?
    @ObservedObject private var share = ShareActivityStore.shared

    var body: some View {
        if share.isBroadcasting(sessionId: sessionId) {
            Label(text, systemImage: "dot.radiowaves.left.and.right")
                .font(.bodySM)
                .foregroundColor(.signalGreen)
                .accessibilityIdentifier("menubar.share-live")
        }
    }

    private var text: String {
        share.watchers.isEmpty
            ? String(localized: "share.live.on")
            : String(format: String(localized: "share.live.on_count_format"), Int64(share.watchers.count))
    }
}

/// 录音药丸上的一粒电波:此刻这场录音的字幕在离开这台机器。
/// 药丸不接鼠标,所以只给被动指示。
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
