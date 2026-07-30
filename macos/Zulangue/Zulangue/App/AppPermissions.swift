// AppPermissions.swift
// Notebook Capture 所需的麦克风权限检测与引导。

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

    var settingsUrl: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
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
                        name: .zulanguePermissionsMayHaveChanged,
                        object: nil
                    )
                }
            }
        }
    }

    static func missing() -> [AppPermission] {
        AppPermission.allCases.filter { status(for: $0) != .granted }
    }
}

extension Notification.Name {
    /// mic 授权完成后 post,让 onboarding 立即 refresh 权限状态
    static let zulanguePermissionsMayHaveChanged = Notification.Name("ZulanguePermissionsMayHaveChanged")
}

enum PermissionStatus {
    case notDetermined
    case granted
    case denied
}
