import AppKit
import SwiftUI

enum SubtitleOverlayFontPolicy {
    static let defaultsKey = "zulangue.subtitleOverlay.fontSize"
    static let minimum = 18.0
    static let maximum = 64.0
    static let defaultValue = 30.0
    static let step = 4.0

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    static func smaller(than value: Double) -> Double {
        clamped(value - step)
    }

    static func larger(than value: Double) -> Double {
        clamped(value + step)
    }
}

struct SubtitleOverlayView: View {
    @ObservedObject var store: ActiveBilingualTranscriptStore
    @ObservedObject private var coordinator = SubtitleOverlayCoordinator.shared
    @AppStorage(SubtitleOverlayFontPolicy.defaultsKey)
    private var storedFontSize = SubtitleOverlayFontPolicy.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider().overlay(Color.white.opacity(0.12))
            subtitleBody
        }
        .frame(minWidth: 560, minHeight: 180)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.utterances)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "subtitle.overlay.accessibility_label")))
        .accessibilityValue(Text(String(
            format: String(localized: "subtitle.overlay.language_count"),
            store.selectedLanguages.count
        )))
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            CaptureStateLabel(
                captureState: store.captureState,
                remoteHealth: store.remoteHealth,
                projectionState: store.projectionState
            )

            Text(String(localized: "subtitle.overlay.title"))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            Spacer(minLength: 16)

            fontControls

            Button {
                coordinator.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(String(localized: "common.close"))
            .accessibilityLabel(Text(String(localized: "common.close")))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .help(String(localized: "subtitle.overlay.move_resize_hint"))
    }

    private var fontControls: some View {
        HStack(spacing: 2) {
            fontButton(
                systemImage: "textformat.size.smaller",
                label: String(localized: "subtitle.overlay.font_smaller"),
                identifier: AccessibilityID.floatingSubtitleFontSmaller,
                disabled: fontSize <= SubtitleOverlayFontPolicy.minimum
            ) {
                storedFontSize = SubtitleOverlayFontPolicy.smaller(than: fontSize)
            }

            Text(verbatim: "\(Int(fontSize))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 28)
                .accessibilityLabel(Text(String(localized: "subtitle.overlay.font_size")))
                .accessibilityValue(Text(verbatim: "\(Int(fontSize))"))

            fontButton(
                systemImage: "textformat.size.larger",
                label: String(localized: "subtitle.overlay.font_larger"),
                identifier: AccessibilityID.floatingSubtitleFontLarger,
                disabled: fontSize >= SubtitleOverlayFontPolicy.maximum
            ) {
                storedFontSize = SubtitleOverlayFontPolicy.larger(than: fontSize)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }

    private func fontButton(
        systemImage: String,
        label: String,
        identifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }

    private var subtitleBody: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    languageHeader
                    Divider().overlay(Color.white.opacity(0.1))
                    transcriptContent
                }
                .frame(
                    width: max(geometry.size.width, minimumContentWidth),
                    height: geometry.size.height
                )
            }
            .scrollIndicators(store.selectedLanguages.count > 3 ? .visible : .hidden)
        }
    }

    private var languageHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(store.selectedLanguages.enumerated()), id: \.offset) { index, language in
                VStack(alignment: .leading, spacing: 1) {
                    Text(languageName(language))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(displayLanguageCode(language))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if index < store.selectedLanguages.count - 1 {
                    Divider().overlay(Color.white.opacity(0.1))
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if store.isCaptureActive == false {
            emptyState(
                String(localized: "subtitle.overlay.recording_ended"),
                systemImage: "checkmark.circle"
            )
        } else if store.utterances.isEmpty {
            emptyState(
                String(localized: "subtitle.overlay.waiting"),
                systemImage: "waveform"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.utterances.suffix(4)) { utterance in
                        subtitleRow(utterance)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.visible)
        }
    }

    private func emptyState(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: max(fontSize * 0.58, 14), weight: .medium))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    @ViewBuilder
    private func subtitleRow(_ utterance: NotebookCaptureUtteranceDTO) -> some View {
        let projection = store.projection(for: utterance)

        if let pendingLanguage = projection.pendingLanguage {
            statusRow(
                title: String(localized: "capture.transcript.language_pending"),
                detail: pendingLanguage,
                systemImage: "ellipsis",
                color: .secondary
            )
        } else if let outsideText = projection.unselectedLanguageText {
            statusRow(
                title: String(
                    format: String(localized: "capture.transcript.unselected_language"),
                    displayLanguageCode(utterance.sourceLanguage)
                ),
                detail: outsideText,
                systemImage: "character.bubble",
                color: .secondary
            )
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(projection.lanes.enumerated()), id: \.offset) { index, lane in
                    subtitleLane(lane)
                    if index < projection.lanes.count - 1 {
                        Divider().overlay(Color.white.opacity(0.1))
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
        }
    }

    private func subtitleLane(_ lane: NotebookCaptureLanguageLane) -> some View {
        Group {
            if let text = lane.text, text.isEmpty == false {
                Text(text)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            } else if lane.missingLaneState == .waiting {
                Label(
                    String(
                        format: String(localized: "capture.transcript.waiting_lane"),
                        displayLanguageCode(lane.language)
                    ),
                    systemImage: "ellipsis"
                )
                .foregroundColor(.secondary)
            } else if lane.missingLaneState == .failed {
                Label(
                    String(
                        format: String(localized: "capture.transcript.failed_lane"),
                        displayLanguageCode(lane.language)
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundColor(.orange)
            } else {
                Text("—")
                    .foregroundColor(.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: CGFloat(fontSize), weight: .medium))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: CGFloat(fontSize * 2.35), alignment: .topLeading)
    }

    private func statusRow(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundColor(color)
            if detail.isEmpty == false {
                Text(detail)
                    .font(.system(size: CGFloat(fontSize), weight: .medium))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private var fontSize: Double {
        SubtitleOverlayFontPolicy.clamped(storedFontSize)
    }

    private var minimumContentWidth: CGFloat {
        let columnWidth = max(220, CGFloat(fontSize * 7.0))
        return CGFloat(max(store.selectedLanguages.count, 1)) * columnWidth
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: normalizedLanguageCode(code))
            ?? displayLanguageCode(code)
    }

    private func displayLanguageCode(_ code: String) -> String {
        normalizedLanguageCode(code).uppercased()
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        code
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? code.lowercased()
    }
}

@MainActor
final class SubtitleOverlayController: NSWindowController, ManagedWindowControllerV2, NSWindowDelegate {
    private static let savedFrameKey = "zulangue.subtitleOverlay.frame"

    private let store: ActiveBilingualTranscriptStore
    private var hostingView: NSHostingView<SubtitleOverlayView>?

    var windowSurfaceID: WindowSurfaceID { .subtitleOverlay }
    var managedWindow: NSWindow {
        guard let window else { preconditionFailure("SubtitleOverlayController.window missing") }
        return window
    }

    init(store: ActiveBilingualTranscriptStore) {
        self.store = store
        let spec = WindowSpecV2.required(.subtitleOverlay)
        let panel = NSPanel(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(WindowSurfaceID.subtitleOverlay.rawValue)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        configureManagedWindow()
        configurePanel()
        installRootView()
        managedWindow.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        super.close()
        WindowCoordinator.shared.didCloseManagedSurface(.subtitleOverlay)
        SubtitleOverlayCoordinator.shared.surfaceDidClose()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistFrame()
    }

    var storeForTesting: ActiveBilingualTranscriptStore {
        store
    }

    static func loadSavedFrame(defaults: UserDefaults = .standard) -> NSRect? {
        guard let encoded = defaults.string(forKey: savedFrameKey) else { return nil }
        let rect = NSRectFromString(encoded)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private func configurePanel() {
        guard let panel = managedWindow as? NSPanel else { return }
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
    }

    private func installRootView() {
        let hostingView = WindowHostingV2.makeView(
            rootView: SubtitleOverlayView(store: store),
            policy: managedWindowSpec.hostingPolicy
        )
        WindowHostingV2.installPinnedView(hostingView, into: managedWindow)
        _ = WindowHostingV2.stabilizeWindowTree(on: managedWindow)
        self.hostingView = hostingView
        managedWindow.contentViewController = nil
    }

    private func persistFrame(defaults: UserDefaults = .standard) {
        defaults.set(NSStringFromRect(managedWindow.frame), forKey: Self.savedFrameKey)
    }
}
