// Toast.swift
// 全局 Toast 反馈组件 — Instrument Cipher 风格
// 权威：spec §8 状态反馈层级 + §9 颜色语义规则

import SwiftUI
import Combine

// MARK: - Toast Model

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String?
    let timestamp: Date
    var autoDismissAfter: TimeInterval = 5

    enum Kind {
        case info
        case success
        case warning
        case error

        var icon: String {
            switch self {
            case .info:    return "info.circle"
            case .success: return "checkmark.circle"
            case .warning: return "exclamationmark.triangle"
            case .error:   return "xmark.octagon"
            }
        }

        var color: Color {
            switch self {
            case .info:    return .info
            case .success: return .success
            case .warning: return .warning
            case .error:   return .error
            }
        }

        var label: String {
            switch self {
            case .info:    return "INFO"
            case .success: return "OK"
            case .warning: return "WARN"
            case .error:   return "ERROR"
            }
        }
    }
}

// MARK: - ToastCenter

/// 全局 Toast 调度中心
///
/// 任何 Swift 代码都可调用：
/// ```swift
/// ToastCenter.shared.error("Capture failed", detail: "\(error)")
/// ToastCenter.shared.success("Context Pack saved")
/// ```
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var toasts: [Toast] = []

    private var dismissTimers: [UUID: Timer] = [:]

    private init() {}

    func info(_ title: String, detail: String? = nil) {
        post(Toast(kind: .info, title: title, detail: detail, timestamp: Date()))
    }

    func success(_ title: String, detail: String? = nil) {
        post(Toast(kind: .success, title: title, detail: detail, timestamp: Date()))
    }

    func warning(_ title: String, detail: String? = nil) {
        post(Toast(kind: .warning, title: title, detail: detail, timestamp: Date()))
    }

    func error(_ title: String, detail: String? = nil) {
        post(Toast(
            kind: .error,
            title: title,
            detail: detail,
            timestamp: Date(),
            autoDismissAfter: 8 // errors stay longer
        ))
    }

    func post(_ toast: Toast) {
        toasts.append(toast)
        // 限制最多 4 个同时显示
        if toasts.count > 4 {
            toasts.removeFirst(toasts.count - 4)
        }

        // UI test 模式跳过 auto-dismiss，便于 XCUITest 断言 toast 文案。
        if TestEnvironment.shouldDisableToastAutoDismiss {
            return
        }

        let id = toast.id
        let delay = toast.autoDismissAfter
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self, id] in
                self?.dismiss(id: id)
            }
        }
        dismissTimers[id] = timer
    }

    func dismiss(id: UUID) {
        toasts.removeAll { $0.id == id }
        dismissTimers[id]?.invalidate()
        dismissTimers.removeValue(forKey: id)
    }

    func dismissAll() {
        toasts.removeAll()
        for (_, timer) in dismissTimers {
            timer.invalidate()
        }
        dismissTimers.removeAll()
    }
}

// MARK: - ToastView (single toast row)

struct ToastView: View {
    let toast: Toast
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: toast.kind.icon)
                .iconSizeMedium()
                .foregroundColor(toast.kind.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(toast.kind.label)
                        .font(Font.mono8)
                        .foregroundColor(toast.kind.color)
                        .tracking(0.6)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(toast.kind.color.opacity(0.15))
                        .cornerRadius(Radius.xs)

                    Text(toast.title)
                        .font(Font.sans12)
                        .foregroundColor(Color.textPrimary)
                        .lineLimit(2)
                }

                if let detail = toast.detail {
                    Text(detail)
                        .font(Font.mono9)
                        .foregroundColor(Color.textTertiary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.textTertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(toast.kind.color.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 4)
    }
}

// MARK: - ToastOverlay

/// 把 Toast 列表叠加到任意视图右下角
struct ToastOverlay: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    ForEach(center.toasts) { toast in
                        ToastView(toast: toast, onDismiss: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                center.dismiss(id: toast.id)
                            }
                        })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(20)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: center.toasts)
            }
    }
}

extension View {
    /// 把 Toast 全局叠加到这个视图
    func toastOverlay() -> some View {
        self.modifier(ToastOverlay())
    }
}
