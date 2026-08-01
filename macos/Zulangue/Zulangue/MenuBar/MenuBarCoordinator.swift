import AppKit
import Combine
import SwiftUI

/// Owns the menu-bar status item and the popover it presents.
///
/// Single source of truth for "where does the app live in the menu bar". Other
/// surfaces (main window, floating panel, captions, operator panel) remain
/// managed by `WindowCoordinator`; this coordinator covers the new top-right
/// entry that replaced the Dynamic Island.
///
/// Lifecycle: created and `install()`-ed once from
/// `ZulangueAppDelegate.applicationDidFinishLaunching`. The status item then
/// lives for the rest of the app's lifetime and is independent of any window
/// state — closing the main window does not affect it.
///
/// Click behavior: both left-click and right-click toggle the popover. A
/// dedicated right-click NSMenu would duplicate options that already live in
/// the popover, and many of those options are state-dependent (Stop is only
/// valid while recording, Resume is only valid while paused) — which a static
/// NSMenu can't express cleanly. Keeping a single popover surface is also more
/// discoverable for non-power-users.
@MainActor
final class MenuBarCoordinator: NSObject {
    static let shared = MenuBarCoordinator()

    private let store: MenuBarRuntimeStore
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    private var pulseTimer: Timer?
    private var pulseShowingDimVariant = false
    private var hasInstalled = false

    var isInstalled: Bool { hasInstalled && statusItem != nil }

    init(store: MenuBarRuntimeStore? = nil) {
        // Touching `MenuBarRuntimeStore.shared` from an init that the compiler
        // sees as nonisolated triggers a Swift 6 warning. `MainActor.assumeIsolated`
        // mirrors the pattern used by `MenuBarSuppressionCoordinator` — the
        // singleton is only ever constructed on the main actor (AppDelegate
        // boot path), and tests construct it on the @MainActor test queue.
        self.store = store ?? MainActor.assumeIsolated { MenuBarRuntimeStore.shared }
        super.init()
    }

    /// Stand up the status item + popover. Idempotent — safe to call multiple
    /// times. Skipped under unit tests because NSStatusBar is not safe to touch
    /// from XCTest processes without a real run loop.
    func install() {
        guard !hasInstalled else { return }
        guard !TestEnvironment.isUnitTestMode else { return }
        hasInstalled = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.behavior = []
        if let button = item.button {
            button.image = MenuBarStatusItemIcon.idle
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleButtonClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Zulangue"
            button.setAccessibilityIdentifier(AccessibilityID.menuBarStatusItem)
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverRootView(store: store)
        )
        self.popover = popover

        observeState()
        refreshIcon(for: store.state, suppression: store.suppressionReason)
    }

    /// Tear down the status item — only used by tests via `resetForTesting`.
    func uninstall() {
        cancellables.removeAll()
        stopPulse()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover?.close()
        popover = nil
        hasInstalled = false
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    func resetForTesting() {
        uninstall()
    }

    // MARK: - Click handling

    @objc private func handleButtonClick(_ sender: NSStatusBarButton) {
        // Left and right click both open the popover; see class docstring for why.
        togglePopover(relativeTo: sender)
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // A status-item action is delivered even while another application
            // is frontmost, but its popover is not guaranteed to become the
            // active interactive surface. Activate before presenting so the
            // popover appears above Chrome and other frontmost applications.
            // Presenting first and activating afterwards can immediately disturb
            // a transient popover's focus, which is why the ordering matters.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - State observation

    private func observeState() {
        store.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.refreshIcon(for: state, suppression: self.store.suppressionReason)
            }
            .store(in: &cancellables)

        store.$suppressionReason
            .receive(on: RunLoop.main)
            .sink { [weak self] reason in
                guard let self else { return }
                self.refreshIcon(for: self.store.state, suppression: reason)
            }
            .store(in: &cancellables)
    }

    private func refreshIcon(
        for state: MenuBarRuntimeState,
        suppression: MenuBarSuppressionReason?
    ) {
        guard let button = statusItem?.button else { return }

        if suppression == .privacy {
            stopPulse()
            button.image = MenuBarStatusItemIcon.micDenied
            return
        }

        switch state {
        case .idle:
            stopPulse()
            button.image = MenuBarStatusItemIcon.idle

        case .recordingCompact(let info), .recordingExpanded(let info, _):
            if info.isPaused {
                stopPulse()
                button.image = MenuBarStatusItemIcon.recordingPaused
            } else {
                startPulseIfNeeded(button: button)
            }

        case .backgroundProcessing:
            stopPulse()
            button.image = MenuBarStatusItemIcon.processing
        }
    }

    // MARK: - Pulse timer

    /// Pulse the recording icon between full and dim variants every 0.6s so the
    /// user has a calm but unambiguous "still recording" signal in the menu bar.
    /// Faster than this reads as nervous; slower reads as inert. Cancelled the
    /// instant state moves out of active recording.
    private func startPulseIfNeeded(button: NSStatusBarButton) {
        if pulseTimer != nil { return }
        button.image = MenuBarStatusItemIcon.recording
        pulseShowingDimVariant = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickPulse()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func tickPulse() {
        // Re-guard: the timer block re-dispatches through Task { @MainActor }, so a
        // tick that fired before `stopPulse()` invalidated the timer can still land
        // here on the next main-actor turn. Without this check, a mid-recording
        // permission revocation would let one rogue tick overwrite the just-set
        // `mic.slash` suppression icon with the recording dot for ~600ms.
        guard pulseTimer != nil,
              store.suppressionReason == nil,
              store.state.isRecording
        else { return }
        guard let button = statusItem?.button else { return }
        pulseShowingDimVariant.toggle()
        button.image = pulseShowingDimVariant
            ? MenuBarStatusItemIcon.recordingDim
            : MenuBarStatusItemIcon.recording
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseShowingDimVariant = false
    }
}
