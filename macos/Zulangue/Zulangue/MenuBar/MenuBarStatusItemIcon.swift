import AppKit

/// Builds the NSImage that sits in the menu-bar status item.
///
/// Idle / processing icons are template images that auto-tint to the menu-bar's
/// foreground color (dark in light mode, light in dark mode). The recording and
/// suppressed icons are *non-template* and explicitly painted in signal orange
/// (`#FF6B00`) per design-system/MASTER.md §SIGNAL: this is the one approved
/// "currently happening" color and the only place we are allowed to break the
/// template tint to surface that state to the user. Recording pulses by
/// alternating between the full-opacity and dim variants every 0.6s.
@MainActor
enum MenuBarStatusItemIcon {
    static let iconPointSize: CGFloat = 16
    static let imageSize = NSSize(width: 18, height: 18)

    /// Canonical signal orange (`#FF6B00` per MASTER.md §SIGNAL). Stays an
    /// `NSColor` literal because `NSImage.SymbolConfiguration(paletteColors:)`
    /// needs AppKit colors — SwiftUI's `Color.accentOrange` resolves to the
    /// same hex but doesn't bridge to `NSColor` for palette config. Identical
    /// value as `Color.accentOrange` in both light and dark mode.
    static let signalOrange = NSColor(srgbRed: 1.0, green: 107.0 / 255.0, blue: 0.0, alpha: 1.0)

    /// The Zulangue mark is a template image so macOS handles light/dark
    /// menu-bar contrast.
    static let idle: NSImage = {
        let image = NSImage(named: "ZulangueMark")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Zulangue")
            ?? NSImage()
        return fitted(image, isTemplate: true)
    }()

    /// Spinner glyph for background-processing state. Static (popover shows
    /// the actual progress bar) — animating it in the menu bar would be noise.
    static let processing: NSImage = {
        let image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Processing"
        ) ?? NSImage()
        return fitted(image, isTemplate: true)
    }()

    /// Mic-denied glyph, painted signal orange. Click in popover opens
    /// System Settings → Privacy → Microphone.
    static let micDenied: NSImage = paletteIcon(
        symbolName: "mic.slash.fill",
        color: signalOrange,
        accessibilityDescription: "Microphone permission denied"
    )

    /// Recording dot, full brightness. Pulse alternates this with `recordingDim`.
    static let recording: NSImage = paletteIcon(
        symbolName: "record.circle.fill",
        color: signalOrange,
        accessibilityDescription: "Recording"
    )

    /// Recording dot, dimmed (half-brightness). Drives the pulse trough.
    static let recordingDim: NSImage = paletteIcon(
        symbolName: "record.circle.fill",
        color: signalOrange.withAlphaComponent(0.45),
        accessibilityDescription: "Recording"
    )

    /// Paused recording — same hue as recording but a `pause.circle.fill`
    /// glyph so the user can distinguish at a glance.
    static let recordingPaused: NSImage = paletteIcon(
        symbolName: "pause.circle.fill",
        color: signalOrange,
        accessibilityDescription: "Recording paused"
    )

    private static func paletteIcon(
        symbolName: String,
        color: NSColor,
        accessibilityDescription: String
    ) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let base = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        ) ?? NSImage()
        let tinted = base.withSymbolConfiguration(config) ?? base
        return fitted(tinted, isTemplate: false)
    }

    private static func fitted(_ image: NSImage, isTemplate: Bool) -> NSImage {
        let fittedImage = (image.copy() as? NSImage) ?? image
        fittedImage.size = imageSize
        fittedImage.isTemplate = isTemplate
        return fittedImage
    }
}
