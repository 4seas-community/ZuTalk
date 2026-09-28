// ShareNotifications.swift
// 有人请求加入时的系统通知。
//
// 敲门一分钟就超时。主持人在录音、在讲话,ZuTalk 多半不在前台 —— 窗口里
// 的横条与 Dock 弹跳都可能被错过。系统通知带着「让对方进来 / 拒绝」两个
// 按钮,在哪儿都能当场回答。ZuTalk 在前台时不发:窗口顶上的横条已经在了。
//
// 权限只在第一次开始共享时问 —— 那是它第一次有用的时候,不在启动时就问。

import AppKit
import UserNotifications

@MainActor
final class ShareNotifications: NSObject {
    static let shared = ShareNotifications()

    private static let joinCategory = "zutalk.share.join-request"
    private static let approveAction = "approve"
    private static let declineAction = "decline"
    nonisolated private static let requestKey = "requestId"

    private var installed = false
    private var posted: Set<String> = []

    private var center: UNUserNotificationCenter { .current() }

    /// 挂上代理与按钮。启动时调用一次;不问权限。
    func install() {
        guard installed == false, Bundle.main.bundleIdentifier != nil else { return }
        installed = true
        center.delegate = self
        let approve = UNNotificationAction(
            identifier: Self.approveAction,
            title: String(localized: "share.knock.approve"),
            options: []
        )
        let decline = UNNotificationAction(
            identifier: Self.declineAction,
            title: String(localized: "share.knock.decline"),
            options: [.destructive]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.joinCategory,
                actions: [approve, decline],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    /// 开始共享时问一次。拒绝了也没关系:窗口里的横条照旧在。
    func requestPermissionIfNeeded() {
        guard installed else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// 新的敲门。ZuTalk 在前台时不发。
    func announce(_ request: FfiJoinRequest, title: String) {
        guard installed, NSApp.isActive == false, posted.contains(request.requestId) == false else {
            return
        }
        posted.insert(request.requestId)
        let content = UNMutableNotificationContent()
        content.title = String(
            format: String(localized: "share.knock.title_format"),
            request.displayName.isEmpty ? String(localized: "share.unnamed") : request.displayName
        )
        content.body = String(
            format: String(localized: "share.knock.notification_body_format"),
            title.isEmpty ? String(localized: "share.untitled") : title,
            request.shortLabel
        )
        content.sound = .default
        content.categoryIdentifier = Self.joinCategory
        content.userInfo = [Self.requestKey: request.requestId]
        center.add(UNNotificationRequest(identifier: request.requestId, content: content, trigger: nil))
    }

    /// 已经回答、或已过期的请求:把通知撤下,免得有人去点一个早就不算数的按钮。
    func withdraw(except live: Set<String>) {
        let stale = posted.subtracting(live)
        guard stale.isEmpty == false else { return }
        posted.subtract(stale)
        center.removeDeliveredNotifications(withIdentifiers: Array(stale))
    }

    fileprivate func handle(action: String, requestId: String) {
        let share = ShareActivityStore.shared
        guard let request = share.pendingJoinRequests.first(where: { $0.requestId == requestId }) else {
            if action != UNNotificationDefaultActionIdentifier {
                ToastCenter.shared.warning(String(localized: "share.knock.expired"))
            }
            return
        }
        switch action {
        case Self.approveAction:
            share.approve(request)
        case Self.declineAction:
            share.decline(request)
        default:
            // 点了通知本身:把窗口叫出来,横条就在顶上。
            NSApp.activate(ignoringOtherApps: true)
            WindowCoordinator.shared.showMainWindow()
        }
    }
}

extension ShareNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let requestId = response.notification.request.content.userInfo[Self.requestKey] as? String
        Task { @MainActor in
            if let requestId {
                ShareNotifications.shared.handle(action: action, requestId: requestId)
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 在前台时窗口顶上已经有横条,不再重复弹。
        completionHandler([])
    }
}
