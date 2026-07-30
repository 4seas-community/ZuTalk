import AppKit
import Foundation

/// Watches inputs that should swap the menu-bar icon to a remediation state
/// and forwards them to `MenuBarRuntimeStore.setSuppressed`.
@MainActor
final class MenuBarSuppressionCoordinator {
    static let shared = MenuBarSuppressionCoordinator()

    private let store: MenuBarRuntimeStore
    private let micStatusProvider: () -> PermissionStatus
    private var permissionsObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var hasStarted = false

    init(
        store: MenuBarRuntimeStore? = nil,
        micStatusProvider: (() -> PermissionStatus)? = nil
    ) {
        // Touching `MenuBarRuntimeStore.shared` from an init that the compiler
        // sees as nonisolated triggers a Swift 6 warning. `MainActor.assumeIsolated`
        // is correct here — the singletons are only ever constructed on the main
        // actor (AppDelegate.applicationDidFinishLaunching path), and tests
        // construct them on the @MainActor test queue.
        self.store = store ?? MainActor.assumeIsolated { MenuBarRuntimeStore.shared }
        self.micStatusProvider = micStatusProvider ?? {
            AppPermissions.status(for: .microphone)
        }
    }

    /// Idempotent — safe to call multiple times. Skips entirely under unit tests
    /// to avoid NotificationCenter side effects.
    func start() {
        guard !hasStarted else { return }
        guard !TestEnvironment.isUnitTestMode else { return }
        hasStarted = true

        permissionsObserver = NotificationCenter.default.addObserver(
            forName: .zulanguePermissionsMayHaveChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcile()
            }
        }

        // The system never broadcasts when the user toggles a permission in
        // System Settings, but it does send didBecomeActive when they switch
        // back to Zulangue — that's our cue to re-check.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcile()
            }
        }

        reconcile()
    }

    func stop() {
        for observer in [permissionsObserver, didBecomeActiveObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        permissionsObserver = nil
        didBecomeActiveObserver = nil
        hasStarted = false
    }

    /// Recompute the desired suppression reason from current inputs and push it
    /// to the store. Visible for testing — production callers should rely on the
    /// notification observers.
    func reconcile() {
        store.setSuppressed(resolveReason())
    }

    private func resolveReason() -> MenuBarSuppressionReason? {
        // .notDetermined deliberately maps to nil so the recording flow's first
        // request can trigger the system prompt without the menu bar showing a
        // scary mic.slash beforehand.
        switch micStatusProvider() {
        case .denied:
            return .privacy
        case .granted, .notDetermined:
            return nil
        }
    }
}
