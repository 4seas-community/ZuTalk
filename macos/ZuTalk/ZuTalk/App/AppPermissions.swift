// AppPermissions.swift
// Notebook Capture 所需的麦克风权限检测与引导。

import AppKit
import AVFoundation
import Foundation

enum AppPermission: String, CaseIterable {
    case microphone

    var displayName: String {
        String(localized: "permission.microphone.name")
    }

    var usage: String {
        String(localized: "permission.microphone.usage")
    }

    /// 系统设置里这项权限的那一页(隐私与安全性 › 麦克风)。
    var settingsUrl: URL {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        }
    }
}

enum AppPermissions {
    static func status(for perm: AppPermission) -> PermissionStatus {
        switch perm {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:          return .granted
            case .denied, .restricted: return .denied
            case .notDetermined:       return .notDetermined
            @unknown default:          return .notDetermined
            }
        }
    }

    @MainActor
    static func request(_ perm: AppPermission) {
        switch perm {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .zutalkPermissionsMayHaveChanged,
                        object: nil
                    )
                }
            }
        }
    }

    /// 打开系统设置里这项权限的那一页。人拒绝过一次以后,系统不会再弹授权框,
    /// `request` 再调也没有动静;这时候唯一的路是带人到开关跟前。
    @MainActor
    static func openSystemSettings(for perm: AppPermission) {
        NSWorkspace.shared.open(perm.settingsUrl)
    }

    static func missing() -> [AppPermission] {
        AppPermission.allCases.filter { status(for: $0) != .granted }
    }
}

extension Notification.Name {
    /// mic 授权完成后 post,让 onboarding 立即 refresh 权限状态
    static let zutalkPermissionsMayHaveChanged = Notification.Name("ZuTalkPermissionsMayHaveChanged")
}

enum PermissionStatus {
    case notDetermined
    case granted
    case denied
}
