import AppKit
import Combine
import SwiftUI

/// Owns the `RecordingHudPanel` lifecycle. Decides when to show it: only when
/// recording is active AND the menu bar is currently auto-hidden (full-screen
/// app, or the user's System Settings "Automatically hide and show the menu
/// bar" preference). In normal-mode usage the panel never appears, so the
/// menu-bar simplification the rip achieved is preserved.
///
/// Menu-bar visibility heuristic: `NSScreen.main.frame.maxY - visibleFrame.maxY`
/// equals the visible menu-bar height. Standard menu bar is 24–28pt. When
/// macOS auto-hides it (full-screen or always-hide preference), the visibleFrame
/// extends to include the menu-bar area and the difference collapses to ~0.
/// We use `< 10pt` as the threshold to absorb any small ambient inset.
@MainActor
final class RecordingHudController {
    static let shared = RecordingHudController()

    private let store: MenuBarRuntimeStore
    private var panel: RecordingHudPanel?
    private var hostingView: NSHostingView<RecordingHudView>?
    private var stateCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var hasInstalled = false

    init(store: MenuBarRuntimeStore? = nil) {
        // Touching `MenuBarRuntimeStore.shared` from a default expression is seen
        // by the compiler as nonisolated. `MainActor.assumeIsolated` is correct
        // here — the singleton is only constructed on the main actor (AppDelegate
        // path), and tests construct it on the @MainActor test queue.
        self.store = store ?? MainActor.assumeIsolated { MenuBarRuntimeStore.shared }
    }

    /// Stand up the observers and (lazily) the panel. Idempotent; skipped in
    /// unit-test mode to avoid NSPanel side effects.
    func install() {
        guard !hasInstalled else { return }
        guard !TestEnvironment.isUnitTestMode else { return }
        hasInstalled = true

        stateCancellable = store.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconcile()
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcile()
            }
        }

        // Active-space change is the primary cue for full-screen enter/exit.
        // macOS posts it from the workspace center, not the app center.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcile()
            }
        }

        reconcile()
    }

    func uninstall() {
        stateCancellable?.cancel()
        stateCancellable = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        screenObserver = nil
        spaceObserver = nil
        hidePanel()
        hasInstalled = false
    }

    func resetForTesting() {
        uninstall()
    }

    var isPresentingForTesting: Bool {
        panel?.isVisible == true
    }

    // MARK: - Decision

    private func reconcile() {
        // Recording states get the pill; everything else (including
        // `.backgroundProcessing`) hides it. backgroundProcessing means the mic
        // is already closed and Rust is post-processing the saved audio, so
        // the privacy-visibility gap doesn't apply — no need to overlay
        // full-screen apps while transcription churns in the background.
        let info: RecordingInfo
        switch store.state {
        case .recordingCompact(let i),
             .recordingExpanded(let i, _):
            info = i
        case .idle, .backgroundProcessing:
            hidePanel()
            return
        }
        showOrUpdate(info: info)
    }

    private func showOrUpdate(info: RecordingInfo) {
        guard let target = Self.menuBarHiddenScreen() else {
            hidePanel()
            return
        }
        presentPanel(info: info, on: target)
    }

    /// Returns the first screen on which the menu bar is currently auto-hidden,
    /// or `nil` if every connected screen still shows its menu bar. Used by both
    /// the show/hide decision and the pill's positioning so the pill always
    /// lands on the screen that triggered the decision.
    ///
    /// Multi-monitor correctness: `NSScreen.main` resolves to the screen that
    /// owns the *frontmost key window*, which on a "primary has menu bar +
    /// secondary has full-screen app" layout is usually NOT the screen where
    /// the recording-state regression would bite the user. Iterating
    /// `NSScreen.screens` and surfacing the pill on the actually-hidden one is
    /// the only way to guarantee the indicator reaches the user's eyes.
    ///
    /// `screens:` parameter exists for tests — production callers use the
    /// default `NSScreen.screens`.
    static func menuBarHiddenScreen(screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        screens.first(where: isMenuBarHidden(screen:))
    }

    /// Pure heuristic: a screen counts as "menu bar hidden" when its
    /// `visibleFrame.maxY` collapses to within 10pt of `frame.maxY`. Normal
    /// menu bar contributes 24–28pt; when macOS auto-hides it for a full-screen
    /// app or via the user's preference, the difference goes to ~0. Visible for
    /// testing so `RecordingHudControllerTests` can exercise it on fake screens.
    static func isMenuBarHidden(screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        return (screen.frame.maxY - screen.visibleFrame.maxY) < 10
    }

    // MARK: - Panel lifecycle

    private func presentPanel(info: RecordingInfo, on screen: NSScreen) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let view = RecordingHudView(info: info)
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: RecordingHudPanel.size)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            hostingView = hosting
        }
        positionPanel(panel, on: screen)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            panel.reassertSpacesMembership()
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> RecordingHudPanel {
        RecordingHudPanel()
    }

    private func positionPanel(_ panel: RecordingHudPanel, on screen: NSScreen) {
        // Anchor to the top-right corner of the hidden-menu-bar screen — that's
        // where the NSStatusItem normally lives, so the user's eye is trained
        // there. 8pt right inset mirrors the system menu bar's status-item
        // gutter. Screen comes from `menuBarHiddenScreen()` rather than
        // `NSScreen.main`, which can resolve to the wrong display on
        // multi-monitor setups.
        let frame = NSRect(
            x: screen.frame.maxX - RecordingHudPanel.size.width - 8,
            y: screen.frame.maxY - RecordingHudPanel.size.height - 6,
            width: RecordingHudPanel.size.width,
            height: RecordingHudPanel.size.height
        )
        panel.setFrame(frame, display: true, animate: false)
    }
}
