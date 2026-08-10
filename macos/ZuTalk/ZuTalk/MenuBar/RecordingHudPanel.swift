import AppKit
import SwiftUI

/// Tiny `.fullScreenAuxiliary` NSPanel that shows a pulsing REC pill at the top
/// of the active screen whenever recording is active AND the macOS menu bar is
/// auto-hidden (full-screen apps, "always hide menu bar" preference).
///
/// The menu-bar `NSStatusItem` is hidden with the menu bar in full-screen mode.
/// This display-only pill keeps recording state visible without accepting input.
@MainActor
final class RecordingHudPanel: NSPanel {
    // Dimensions follow the design-system spacing ladder.
    static let size = NSSize(width: 132, height: 24)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        identifier = NSUserInterfaceItemIdentifier("recording-hud")
        isReleasedWhenClosed = false
        // `.floating` sits above normal-level full-screen app content (so the
        // pill is visible in every full-screen scenario) but BELOW
        // `.mainMenu`. That's intentional: when macOS reveals the menu bar in
        // full-screen (cursor at top edge), the menu bar covers the pill
        // momentarily. During that brief reveal the menu bar's own
        // NSStatusItem (signal-orange pulse) carries the same recording
        // signal, so the pill stepping aside avoids obscuring Control Center,
        // clock, and the rest of the status cluster the user is reaching for.
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        isFloatingPanel = true
        hidesOnDeactivate = false
        // Display-only — never interferes with the user's pointer over the
        // full-screen app below. No drag, no click, no key focus.
        ignoresMouseEvents = true
        isMovable = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Reassert spaces membership after macOS reshuffles them on full-screen
    /// toggles. The first display of a `.fullScreenAuxiliary` panel sometimes
    /// gets stuck on the originating space without this nudge.
    func reassertSpacesMembership() {
        let restore = collectionBehavior
        collectionBehavior = []
        collectionBehavior = restore
    }
}
