import AppKit
import Combine
import SwiftUI


struct CaptionOverlayRowV2: Identifiable, Equatable {
    let id: String
    let sourceLanguage: String
    let projection: NotebookCaptureLaneProjection
}


@MainActor
final class CaptionStoreV2: ObservableObject {
    @Published var rows: [CaptionOverlayRowV2] = []
    @Published var selectedLanguages = ["en", "zh"]
    @Published var statusMessage = String(localized: "capture.mirror.idle")
    @Published var fontSize: CGFloat = 36
}

@MainActor
final class OperatorPanelStoreV2: ObservableObject {
    @Published var isRunning = false
    @Published var captureStatus = String(localized: "capture.mirror.idle")
    @Published var selectedLanguages: [String] = []
    @Published var captionFontSize: CGFloat = 36
    @Published var elapsedTime: TimeInterval = 0

    func configure(selectedLanguages: [String]) {
        self.selectedLanguages = selectedLanguages
    }
}

struct FloatingPanelViewV2: View {
    @ObservedObject var store: ActiveBilingualTranscriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CaptureStateLabel(
                    captureState: store.captureState,
                    remoteHealth: store.remoteHealth,
                    projectionState: store.projectionState
                )
                Spacer()
                Label(String(localized: "capture.mirror.read_only"), systemImage: "eye.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: {
                    WindowCommandRouter.shared.requestToggleFloatingPanel()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "common.close")))
            }

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 12) {
                    languageHeader
                    Divider()

                    if store.isCaptureActive == false {
                        Label(
                            String(localized: "capture.mirror.idle"),
                            systemImage: "rectangle.stack"
                        )
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .accessibilityHint(Text(String(localized: "capture.mirror.open_notebook_hint")))
                    } else if store.utterances.isEmpty {
                        Label(
                            String(localized: "capture.transcript.waiting_title"),
                            systemImage: "waveform"
                        )
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(store.utterances.suffix(4)) { utterance in
                                    mirrorRow(utterance)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                }
                .frame(width: floatingContentWidth)
            }
            .scrollIndicators(store.selectedLanguages.count > 2 ? .visible : .hidden)
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 140)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "a11y.floating_panel")))
        .accessibilityHint(Text(String(localized: "capture.mirror.open_notebook_hint")))
    }

    private var languageHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(store.selectedLanguages.enumerated()), id: \.offset) { index, language in
                languageLabel(language)
                if index < store.selectedLanguages.count - 1 {
                    Divider()
                }
            }
        }
        .frame(minHeight: 24)
    }

    private var floatingContentWidth: CGFloat {
        max(448, CGFloat(max(store.selectedLanguages.count, 1)) * 160)
    }

    private func languageLabel(_ language: String) -> some View {
        Text(language.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func mirrorRow(_ utterance: NotebookCaptureUtteranceDTO) -> some View {
        let projection = store.projection(for: utterance)
        if let pendingLanguage = projection.pendingLanguage {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    String(localized: "capture.transcript.language_pending"),
                    systemImage: "ellipsis"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                if pendingLanguage.isEmpty == false {
                    Text(pendingLanguage)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        } else if let outside = projection.unselectedLanguageText {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(
                    format: String(localized: "capture.transcript.unselected_language"),
                    utterance.sourceLanguage.uppercased()
                ))
                .font(.caption)
                .foregroundColor(.secondary)
                Text(outside)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(projection.lanes.enumerated()), id: \.offset) { index, projectedLane in
                    mirrorLane(projectedLane)
                    if index < projection.lanes.count - 1 {
                        Divider()
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        }
    }

    private func mirrorLane(_ projectedLane: NotebookCaptureLanguageLane) -> some View {
        Group {
            if let text = projectedLane.text, text.isEmpty == false {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if projectedLane.missingLaneState == .waiting {
                Label(
                    String(
                        format: String(localized: "capture.transcript.waiting_lane"),
                        projectedLane.language.uppercased()
                    ),
                    systemImage: "ellipsis"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            } else if projectedLane.missingLaneState == .failed {
                Label(
                    String(
                        format: String(localized: "capture.transcript.failed_lane"),
                        projectedLane.language.uppercased()
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
            } else {
                Text("—")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary.opacity(0.55))
                    .accessibilityHidden(true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
    }
}

struct CaptionViewV2: View {
    @ObservedObject var store: CaptionStoreV2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if store.rows.isEmpty {
                VStack {
                    Spacer()
                    Text(store.statusMessage)
                        .font(.system(size: store.fontSize * 0.75, weight: .medium))
                        .foregroundColor(Color.captionPrimary.opacity(0.58))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        VStack(spacing: 16) {
                            HStack(spacing: 0) {
                                ForEach(
                                    Array(store.selectedLanguages.enumerated()),
                                    id: \.offset
                                ) { index, language in
                                    captionLanguageHeader(language)
                                    if index < store.selectedLanguages.count - 1 {
                                        Divider().overlay(Color.captionPrimary.opacity(0.3))
                                    }
                                }
                            }
                            .padding(.horizontal, 40)

                            ScrollView {
                                LazyVStack(spacing: 16) {
                                    ForEach(store.rows) { row in
                                        captionRow(row)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .defaultScrollAnchor(.bottom)
                            .scrollIndicators(.visible)
                        }
                        .padding(.top, 32)
                        .padding(.bottom, 60)
                        .frame(
                            width: max(
                                geometry.size.width,
                                CGFloat(max(store.selectedLanguages.count, 1)) * 240
                            ),
                            height: geometry.size.height
                        )
                    }
                    .scrollIndicators(store.selectedLanguages.count > 3 ? .visible : .hidden)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: store.rows)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "capture.transcript.accessibility_label")))
    }

    @ViewBuilder
    private func captionRow(_ row: CaptionOverlayRowV2) -> some View {
        if let pendingLanguage = row.projection.pendingLanguage {
            VStack(spacing: 8) {
                Label(
                    String(localized: "capture.transcript.language_pending"),
                    systemImage: "ellipsis"
                )
                .font(.system(size: max(store.fontSize * 0.36, 12), weight: .medium))
                .foregroundColor(Color.captionPrimary.opacity(0.58))
                if pendingLanguage.isEmpty == false {
                    Text(pendingLanguage)
                        .font(.system(size: store.fontSize * 0.9, weight: .medium))
                        .foregroundColor(Color.captionPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, minHeight: store.fontSize * 2.4)
        } else if let outside = row.projection.unselectedLanguageText {
            VStack(spacing: 8) {
                Text(String(
                    format: String(localized: "capture.transcript.unselected_language"),
                    row.sourceLanguage.uppercased()
                ))
                .font(.system(size: max(store.fontSize * 0.36, 12), weight: .medium))
                .foregroundColor(Color.captionPrimary.opacity(0.58))
                Text(outside)
                    .font(.system(size: store.fontSize * 0.9, weight: .medium))
                    .foregroundColor(Color.captionPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, minHeight: store.fontSize * 2.4)
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(row.projection.lanes.enumerated()), id: \.offset) { index, projectedLane in
                    captionLane(projectedLane)
                    if index < row.projection.lanes.count - 1 {
                        Divider().overlay(Color.captionPrimary.opacity(0.25))
                    }
                }
            }
            .padding(.horizontal, 40)
            .frame(minHeight: store.fontSize * 2.4)
        }
    }

    private func captionLanguageHeader(_ language: String) -> some View {
        Text(language.uppercased())
            .font(.system(
                size: max(store.fontSize * 0.42, 12),
                weight: .semibold,
                design: .monospaced
            ))
            .tracking(0.8)
            .foregroundColor(Color.captionPrimary.opacity(0.72))
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }

    private func captionLane(_ projectedLane: NotebookCaptureLanguageLane) -> some View {
        Group {
            if let text = projectedLane.text, text.isEmpty == false {
                Text(text)
                    .foregroundColor(Color.captionPrimary)
            } else if projectedLane.missingLaneState == .waiting {
                Label(
                    String(
                        format: String(localized: "capture.transcript.waiting_lane"),
                        projectedLane.language.uppercased()
                    ),
                    systemImage: "ellipsis"
                )
                .foregroundColor(Color.captionPrimary.opacity(0.52))
            } else if projectedLane.missingLaneState == .failed {
                Label(
                    String(
                        format: String(localized: "capture.transcript.failed_lane"),
                        projectedLane.language.uppercased()
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundColor(.orange)
            } else {
                Text("—")
                    .foregroundColor(Color.captionPrimary.opacity(0.34))
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: store.fontSize * 0.9, weight: .medium))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: store.fontSize * 2.4, alignment: .top)
    }
}

struct OperatorPanelViewV2: View {
    @ObservedObject var store: OperatorPanelStoreV2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Circle()
                    .fill(store.isRunning ? Color.successInk : Color.destructive)
                    .frame(width: 10, height: 10)
                Text(store.captureStatus)
                    .font(.headline)
                Spacer()
                if store.isRunning {
                    Text(elapsedText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Label(String(localized: "capture.mirror.read_only"), systemImage: "eye.fill")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "capture.settings.languages.question"))
                    .font(.subheadline.weight(.semibold))

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(store.selectedLanguages, id: \.self) { language in
                            Text(language.uppercased())
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.1))
                                )
                        }
                    }
                }
                .scrollIndicators(.hidden)

                if store.selectedLanguages.count >= 3 {
                    Text(String(localized: "capture.settings.languages.ordered_detail"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack {
                Text(String(localized: "capture.mirror.caption_font"))
                Slider(value: $store.captionFontSize, in: 20...72)
                    .accessibilityLabel(Text(String(localized: "capture.mirror.caption_font")))
                Text(verbatim: "\(Int(store.captionFontSize))")
                    .frame(width: 30)
            }

            Button {
                WindowCommandRouter.shared.openMainWindow(detail: "caption-mirror.open-notebook") {
                    MainNavigationStoreV2.shared.openActiveNotebookForCapture()
                }
            } label: {
                Label(String(localized: "capture.mirror.open_notebook"), systemImage: "rectangle.stack.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityHint(Text(String(localized: "capture.mirror.open_notebook_hint")))

            Spacer()
        }
        .padding()
        .frame(minWidth: 350, minHeight: 320)
    }

    private var elapsedText: String {
        let hours = Int(store.elapsedTime) / 3600
        let minutes = (Int(store.elapsedTime) % 3600) / 60
        let seconds = Int(store.elapsedTime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

@MainActor
final class FloatingPanelControllerV2: NSWindowController, ManagedWindowControllerV2, NSWindowDelegate {
    private static let savedFrameKey = "zulangue.floatingpanel.frame"

    private let store: ActiveBilingualTranscriptStore
    private var hostingView: NSHostingView<FloatingPanelViewV2>?

    var windowSurfaceID: WindowSurfaceID { .floatingPanel }
    var managedWindow: NSWindow {
        guard let window else { preconditionFailure("FloatingPanelControllerV2.window missing") }
        return window
    }

    init(store: ActiveBilingualTranscriptStore) {
        self.store = store
        let spec = WindowSpecV2.required(.floatingPanel)
        let panel = NSPanel(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(WindowSurfaceID.floatingPanel.rawValue)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        configureManagedWindow()
        configurePanelChrome()
        installRootView()
        managedWindow.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installRootView() {
        let hostingView = WindowHostingV2.makeView(
            rootView: FloatingPanelViewV2(store: store),
            policy: managedWindowSpec.hostingPolicy
        )
        WindowHostingV2.installPinnedView(hostingView, into: managedWindow)
        _ = WindowHostingV2.stabilizeWindowTree(on: managedWindow)
        self.hostingView = hostingView
        managedWindow.contentViewController = nil
    }

    func windowDidResize(_ notification: Notification) {
        persistFrame()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    var storeForTesting: ActiveBilingualTranscriptStore? {
        store
    }

    static func loadSavedFrame() -> NSRect? {
        guard let encoded = UserDefaults.standard.string(forKey: savedFrameKey) else { return nil }
        let rect = NSRectFromString(encoded)
        return rect.width > 0 ? rect : nil
    }

    private func configurePanelChrome() {
        managedWindow.standardWindowButton(.closeButton)?.isHidden = true
        managedWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        managedWindow.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func persistFrame() {
        UserDefaults.standard.set(NSStringFromRect(managedWindow.frame), forKey: Self.savedFrameKey)
    }
}

@MainActor
final class CaptionControllerV2: NSWindowController, ManagedWindowControllerV2 {
    private let store: CaptionStoreV2
    private var hostingView: NSHostingView<CaptionViewV2>?
    private var escapeKeyMonitor: Any?

    var windowSurfaceID: WindowSurfaceID { .captionMirror }
    var managedWindow: NSWindow {
        guard let window else { preconditionFailure("CaptionControllerV2.window missing") }
        return window
    }

    var onClose: (() -> Void)?

    init(store: CaptionStoreV2, screen: NSScreen? = nil, onClose: (() -> Void)? = nil) {
        self.store = store
        self.onClose = onClose
        let spec = WindowSpecV2.required(.captionMirror)
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let window = NSWindow(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )
        window.identifier = NSUserInterfaceItemIdentifier(WindowSurfaceID.captionMirror.rawValue)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureManagedWindow()
        installRootView()
        installEscapeKeyMonitor()
    }

    convenience init(screen: NSScreen? = nil, onClose: (() -> Void)? = nil) {
        self.init(store: CaptionStoreV2(), screen: screen, onClose: onClose)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        let onClose = self.onClose
        self.onClose = nil
        removeEscapeKeyMonitor()
        super.close()
        WindowCoordinator.shared.didCloseManagedSurface(.captionMirror)
        onClose?()
    }

    func installRootView() {
        let hostingView = WindowHostingV2.makeView(
            rootView: CaptionViewV2(store: store),
            policy: managedWindowSpec.hostingPolicy
        )
        WindowHostingV2.installPinnedView(hostingView, into: managedWindow)
        _ = WindowHostingV2.stabilizeWindowTree(on: managedWindow)
        self.hostingView = hostingView
        managedWindow.contentViewController = nil
    }

    func setFontSize(_ size: CGFloat) {
        store.fontSize = size
    }

    func moveToScreen(_ screen: NSScreen) {
        let profile = DisplayProfileResolverV2.resolveProfile(from: screen)
        let snapshot = WindowLayoutEngineV2.captionWindowSnapshot(
            for: WindowLayoutRequestV2(
                surfaceID: .captionMirror,
                display: profile,
                systemState: .default,
                currentFrame: managedWindow.frame
            )
        )
        if !WindowCoordinator.shared.applyFrame(
            snapshot.outerFrame,
            to: .captionMirror,
            reason: "caption-mirror.screen-route"
        ) {
            managedWindow.setFrame(snapshot.outerFrame, display: true)
        }
    }

    var onCloseForTesting: (() -> Void)? {
        onClose
    }

    var storeForTesting: CaptionStoreV2 {
        store
    }

    private func installEscapeKeyMonitor() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.close()
                return nil
            }
            return event
        }
    }

    private func removeEscapeKeyMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }
}

@MainActor
final class OperatorPanelControllerV2: NSWindowController, ManagedWindowControllerV2 {
    private let store: OperatorPanelStoreV2
    private var hostingView: NSHostingView<OperatorPanelViewV2>?

    var windowSurfaceID: WindowSurfaceID { .operatorPanel }
    var managedWindow: NSWindow {
        guard let window else { preconditionFailure("OperatorPanelControllerV2.window missing") }
        return window
    }

    init(store: OperatorPanelStoreV2) {
        self.store = store
        let spec = WindowSpecV2.required(.operatorPanel)
        let panel = NSPanel(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(WindowSurfaceID.operatorPanel.rawValue)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        configureManagedWindow()
        installRootView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        super.close()
        WindowCoordinator.shared.didCloseManagedSurface(.operatorPanel)
    }

    func installRootView() {
        let hostingView = WindowHostingV2.makeView(
            rootView: OperatorPanelViewV2(store: store),
            policy: managedWindowSpec.hostingPolicy
        )
        WindowHostingV2.installPinnedView(hostingView, into: managedWindow)
        _ = WindowHostingV2.stabilizeWindowTree(on: managedWindow)
        self.hostingView = hostingView
        managedWindow.contentViewController = nil
    }

    var storeForTesting: OperatorPanelStoreV2? {
        store
    }
}

private func joinTranscriptSegmentsV2(_ segments: [String]) -> String {
    segments
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func normalizedLanguageCodeV2(_ code: String) -> String {
    code
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
        .split(separator: "-")
        .first
        .map(String.init) ?? code.lowercased()
}

private func displayLanguageCodeV2(_ code: String) -> String {
    normalizedLanguageCodeV2(code).uppercased()
}

private func sameLanguageV2(_ lhs: String, _ rhs: String) -> Bool {
    normalizedLanguageCodeV2(lhs) == normalizedLanguageCodeV2(rhs)
}
