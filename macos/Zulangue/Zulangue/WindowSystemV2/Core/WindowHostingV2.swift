import AppKit
import SwiftUI

@available(macOS 13.0, *)
protocol HostingSizingConfigurableV2: AnyObject {
    var sizingOptions: NSHostingSizingOptions { get set }
}

@available(macOS 13.0, *)
extension NSHostingView: HostingSizingConfigurableV2 {}

@available(macOS 13.0, *)
extension NSHostingController: HostingSizingConfigurableV2 {}

private final class FirstMouseHostingViewV2<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class FirstMouseHostingControllerV2<Content: View>: NSHostingController<Content> {
    override init(rootView: Content) {
        super.init(rootView: rootView)
        view = FirstMouseHostingViewV2(rootView: rootView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct HostingSizingStabilizationResultV2 {
    let controllersDisabled: Int
    let viewsDisabled: Int

    var totalDisabled: Int {
        controllersDisabled + viewsDisabled
    }
}

enum WindowHostingV2 {
    @discardableResult
    static func installPinnedContentView<Content: View>(
        rootView: Content,
        into window: NSWindow,
        policy: WindowSpecV2.HostingPolicy = .fixedWindowOwned
    ) -> NSHostingView<Content> {
        let hosting = makeView(rootView: rootView, policy: policy)
        installPinnedView(hosting, into: window)
        return hosting
    }

    static func makeView<Content: View>(
        rootView: Content,
        policy: WindowSpecV2.HostingPolicy = .fixedWindowOwned
    ) -> NSHostingView<Content> {
        let hosting = FirstMouseHostingViewV2(rootView: rootView)
        apply(policy: policy, to: hosting)
        return hosting
    }

    static func makeController<Content: View>(
        rootView: Content,
        policy: WindowSpecV2.HostingPolicy = .fixedWindowOwned
    ) -> NSHostingController<Content> {
        let hosting = FirstMouseHostingControllerV2(rootView: rootView)
        apply(policy: policy, to: hosting)
        guard let hostingView = hosting.view as? NSHostingView<Content> else {
            preconditionFailure("FirstMouseHostingControllerV2 must own an NSHostingView")
        }
        apply(policy: policy, to: hostingView)
        return hosting
    }

    private static func apply<Content: View>(
        policy: WindowSpecV2.HostingPolicy,
        to hosting: NSHostingView<Content>
    ) {
        guard policy == .fixedWindowOwned else { return }
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        if #available(macOS 15.0, *) {
            hosting.sceneBridgingOptions = []
        }
        if #available(macOS 13.3, *) {
            hosting.safeAreaRegions = []
        }
    }

    private static func apply<Content: View>(
        policy: WindowSpecV2.HostingPolicy,
        to hosting: NSHostingController<Content>
    ) {
        guard policy == .fixedWindowOwned else { return }
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        if #available(macOS 15.0, *) {
            hosting.sceneBridgingOptions = []
        }
        if #available(macOS 13.3, *) {
            hosting.safeAreaRegions = []
        }
    }

    static func installPinnedView(_ view: NSView, into window: NSWindow) {
        let container = NSView(frame: window.contentLayoutRect)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window.contentView = container
    }

    @discardableResult
    static func stabilizeWindowTree(on window: NSWindow) -> HostingSizingStabilizationResultV2 {
        if #available(macOS 13.0, *) {
            let controllersDisabled = disableHostingSizing(on: window.contentViewController) ? 1 : 0
            let viewsDisabled = disableHostingSizingRecursively(from: window.contentView)
            return HostingSizingStabilizationResultV2(
                controllersDisabled: controllersDisabled,
                viewsDisabled: viewsDisabled
            )
        }
        return HostingSizingStabilizationResultV2(controllersDisabled: 0, viewsDisabled: 0)
    }

    @available(macOS 13.0, *)
    private static func disableHostingSizing(on object: AnyObject?) -> Bool {
        guard let object = object as? any HostingSizingConfigurableV2 else { return false }
        guard !object.sizingOptions.isEmpty else { return false }
        object.sizingOptions = []
        return true
    }

    @available(macOS 13.0, *)
    private static func disableHostingSizingRecursively(from view: NSView?) -> Int {
        guard let view else { return 0 }
        var disabled = disableHostingSizing(on: view) ? 1 : 0
        for child in view.subviews {
            disabled += disableHostingSizingRecursively(from: child)
        }
        return disabled
    }
}
