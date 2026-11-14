// CityNoticeOverlay.swift
// 窗口底部的一条提示:「已交到档案馆 · <活动>」,旁边一个「打开」。
//
// 停止录音不等上传,交档案馆在后台;交完要有一句话,还要能一下点到档案馆里
// 那一件。`ToastCenter` 的提示不带按钮,所以这一条单独画,叠在主窗口底部
// 正中,不和右下角的普通提示抢位置。
//
// 一条就是:一个图标、一句状态、一个动作。说的是文字交上去了;音频跟在后面
// 一段段交,到哪了看录音上的那一枚,这里不替它说「都交完了」。

import SwiftUI

struct CityNoticeOverlay: ViewModifier {
    @ObservedObject private var city = CityStore.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice = city.notice {
                    CityNoticeView(
                        notice: notice,
                        onAction: { city.performNoticeAction() },
                        onDismiss: { city.dismissNotice(id: notice.id) }
                    )
                    // 活动名再长也不顶到窗口边上。
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.panelTransition, value: city.notice)
    }
}

extension View {
    /// 把「已交到档案馆」这类带按钮的提示叠到这个视图底部。
    func cityNoticeOverlay() -> some View {
        modifier(CityNoticeOverlay())
    }
}

private struct CityNoticeView: View {
    let notice: CityNotice
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .foregroundColor(.success)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.bodySM)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(notice.text)
            if let actionTitle {
                // 这一条唯一的动作,和别处的小控件一个样子。
                ActionPill(actionTitle, systemImage: actionIcon, action: onAction)
                    .accessibilityIdentifier(AccessibilityID.cityNoticeAction)
            }
            Button(action: onDismiss) {
                Image(systemName: Icon.xmark)
                    .iconSizeSmall()
                    .foregroundColor(.textTertiary)
                    .padding(Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "common.close")))
        }
        .padding(.leading, Spacing.xsm)
        .padding(.trailing, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .surfaceCard(
            fill: Color.bgSurface,
            cornerRadius: Radius.md,
            border: Color.borderSubtle,
            borderWidth: Stroke.thin
        )
        .shadow(color: Color.shadowMedium, radius: 12, x: 0, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.cityNotice)
    }

    private var icon: String {
        switch notice.action {
        case .file: return "archivebox"
        case .open, nil: return "checkmark.circle"
        }
    }

    private var actionIcon: String {
        switch notice.action {
        case .file: return "arrow.up.circle"
        case .open, nil: return "arrow.up.right.square"
        }
    }

    private var actionTitle: String? {
        switch notice.action {
        case .open: return String(localized: "city.action.open")
        case .file: return String(localized: "city.action.file")
        case nil: return nil
        }
    }
}
