import AppKit

// CustomTrafficLights.swift
// 自绘窗口红黄绿按钮 — 用纯 AppKit 视图替代 titlebar 里的 SwiftUI NSHostingView。
//
// 为什么不继续用 SwiftUI:
// macOS 26 下主窗口切换到 editor 时会触发一次激烈的 window layout。
// 如果 titlebar 里再手动塞一个 NSHostingView,它会参与 geometry/update cycle,
// 容易把 NSHostingView.updateAnimatedWindowSize 递归炸出来。
//
// 这里改成纯 AppKit:
// - 三颗 12pt 圆点,红/黄/绿,水平间距 8pt
// - hover 热区覆盖窗口内容左上角 92x44 区域,无需触碰屏幕顶边
// - hover 时淡入并显示 x / - / 原生全屏符号
// - 点击走标准 NSWindow API: performClose / performMiniaturize / toggleFullScreen

private enum TrafficLightPalette {
    static let red = NSColor(calibratedRed: 1.00, green: 0.37, blue: 0.34, alpha: 1.0)
    static let yellow = NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.24, alpha: 1.0)
    static let green = NSColor(calibratedRed: 0.31, green: 0.79, blue: 0.27, alpha: 1.0)
    static let symbol = NSColor.black.withAlphaComponent(0.55)
    static let stroke = NSColor.black.withAlphaComponent(0.15)
}

@MainActor
protocol TrafficLightWindowActions: AnyObject {
    func closeFromTrafficLight()
    func miniaturizeFromTrafficLight()
    func toggleFullScreenFromTrafficLight()
}

extension NSWindow: TrafficLightWindowActions {
    func closeFromTrafficLight() {
        performClose(nil)
    }

    func miniaturizeFromTrafficLight() {
        performMiniaturize(nil)
    }

    func toggleFullScreenFromTrafficLight() {
        toggleFullScreen(nil)
    }
}

enum TrafficLightAction {
    case close
    case miniaturize
    case fullScreen

    @MainActor
    func perform(on window: TrafficLightWindowActions) {
        switch self {
        case .close:
            window.closeFromTrafficLight()
        case .miniaturize:
            window.miniaturizeFromTrafficLight()
        case .fullScreen:
            window.toggleFullScreenFromTrafficLight()
        }
    }
}

final class CustomTrafficLightsView: NSView {
    private let buttonStack = NSStackView()
    private let buttons: [TrafficLightButton]
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isHovering = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: 92, height: 44)
    }

    override init(frame frameRect: NSRect) {
        buttons = [
            TrafficLightButton(
                fillColor: TrafficLightPalette.red,
                symbolText: "x",
                action: .close
            ),
            TrafficLightButton(
                fillColor: TrafficLightPalette.yellow,
                symbolText: "-",
                action: .miniaturize
            ),
            TrafficLightButton(
                fillColor: TrafficLightPalette.green,
                symbolText: "↗",
                action: .fullScreen
            ),
        ]
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupView()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    private func setupView() {
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 0
        buttonStack.alignment = .centerY
        buttonStack.distribution = .gravityAreas
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.alphaValue = 0

        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isEnabled = false
            buttonStack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 32),
            ])
        }

        addSubview(buttonStack)
        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            buttonStack.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering

        for button in buttons {
            button.isEnabled = hovering
            button.showsSymbol = hovering
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            buttonStack.animator().alphaValue = hovering ? 1 : 0
        }
    }
}

private final class TrafficLightButton: NSControl {
    private let fillColor: NSColor
    private let symbolText: String
    private let actionKind: TrafficLightAction
    var showsSymbol = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 20, height: 32)
    }

    init(fillColor: NSColor, symbolText: String, action: TrafficLightAction) {
        self.fillColor = fillColor
        self.symbolText = symbolText
        self.actionKind = action
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 32))
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let circleRect = NSRect(
            x: (bounds.width - 12) / 2,
            y: bounds.height - 20,
            width: 12,
            height: 12
        ).insetBy(dx: 0.25, dy: 0.25)
        let circlePath = NSBezierPath(ovalIn: circleRect)
        fillColor.setFill()
        circlePath.fill()
        TrafficLightPalette.stroke.setStroke()
        circlePath.lineWidth = 0.5
        circlePath.stroke()

        guard showsSymbol else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .black),
            .foregroundColor: TrafficLightPalette.symbol,
        ]
        let symbolSize = symbolText.size(withAttributes: attributes)
        let symbolRect = NSRect(
            x: circleRect.midX - symbolSize.width / 2,
            y: circleRect.midY - symbolSize.height / 2 - 0.5,
            width: symbolSize.width,
            height: symbolSize.height
        )
        symbolText.draw(in: symbolRect, withAttributes: attributes)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isEnabled, bounds.contains(point), let window else { return }

        actionKind.perform(on: window)
    }
}
