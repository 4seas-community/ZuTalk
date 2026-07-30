import AppKit

enum MainWindowMetrics {
    static let minWidth: CGFloat = 900
    static let minHeight: CGFloat = 600
    static let defaultWidth: CGFloat = 1320
    static let defaultHeight: CGFloat = 800
    static let autosaveName = "ZulangueMainWindowFrame"
    static let autosaveFrameKey = "NSWindow Frame \(autosaveName)"
    static let persistedFrameKey = "ZulangueMainWindowFrameRect"

    static func launchFrame(in visibleFrame: NSRect) -> NSRect {
        let size = NSSize(
            width: min(defaultWidth, visibleFrame.width),
            height: min(defaultHeight, visibleFrame.height)
        )
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        return NSRect(origin: origin, size: size).integral
    }

    static func parsedAutosavedFrame(from descriptor: String) -> NSRect? {
        let values = descriptor
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        guard values.count >= 4 else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    static func isUsableAutosavedFrame(
        _ frame: NSRect,
        visibleFrame: NSRect
    ) -> Bool {
        guard frame.width >= minWidth, frame.height >= minHeight else {
            return false
        }
        guard frame.width <= visibleFrame.width, frame.height <= visibleFrame.height else {
            return false
        }

        let aspectRatio = frame.width / max(frame.height, 1)
        return aspectRatio >= 1.35
    }

    static func restoredFrame(
        in visibleFrame: NSRect,
        defaults: UserDefaults = .standard
    ) -> NSRect? {
        guard let descriptor = defaults.string(forKey: persistedFrameKey) else {
            return nil
        }

        let frame = NSRectFromString(descriptor)
        guard frame.width > 0, frame.height > 0 else {
            defaults.removeObject(forKey: persistedFrameKey)
            return nil
        }
        guard isUsableAutosavedFrame(frame, visibleFrame: visibleFrame) else {
            defaults.removeObject(forKey: persistedFrameKey)
            return nil
        }

        return frame.integral
    }

    static func persistFrame(
        _ frame: NSRect,
        in visibleFrame: NSRect,
        defaults: UserDefaults = .standard
    ) {
        guard isUsableAutosavedFrame(frame, visibleFrame: visibleFrame) else {
            defaults.removeObject(forKey: persistedFrameKey)
            return
        }
        defaults.set(NSStringFromRect(frame.integral), forKey: persistedFrameKey)
    }

    @discardableResult
    static func sanitizeLegacyAutosavedFrame(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let descriptor = defaults.string(forKey: autosaveFrameKey) else {
            return false
        }
        defaults.removeObject(forKey: autosaveFrameKey)
        return parsedAutosavedFrame(from: descriptor) != nil
    }
}
