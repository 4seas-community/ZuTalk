import AppKit
import Combine
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

enum SubtitleOverlayDisplayMode: String, CaseIterable {
    case conversation
    case audience
}

enum SubtitleOverlayConversationLayout: Equatable {
    case columns
    case stacked
}

enum SubtitleOverlayLayoutPolicy {
    static let maximumLanguageCount = 4

    static func conversationLayout(
        width: CGFloat,
        languageCount: Int,
        fontSize: Double
    ) -> SubtitleOverlayConversationLayout {
        width >= minimumColumnWidth(fontSize: fontSize) * CGFloat(max(languageCount, 1))
            ? .columns
            : .stacked
    }

    static func audienceColumnCount(
        width: CGFloat,
        languageCount: Int,
        fontSize: Double
    ) -> Int {
        let count = min(max(languageCount, 1), maximumLanguageCount)
        let capacity = max(
            1,
            Int(width / minimumAudienceTileWidth(fontSize: fontSize))
        )

        switch count {
        case 1:
            return 1
        case 2:
            return capacity >= 2 ? 2 : 1
        case 3:
            return capacity >= 3 ? 3 : 1
        default:
            if capacity >= 4 { return 4 }
            if capacity >= 2 { return 2 }
            return 1
        }
    }

    static func minimumColumnWidth(fontSize: Double) -> CGFloat {
        max(240, CGFloat(fontSize * 8))
    }

    static func minimumAudienceTileWidth(fontSize: Double) -> CGFloat {
        max(340, CGFloat(fontSize * 10))
    }
}

enum SubtitleOverlayWindowPolicy {
    static let pinnedDefaultsKey = "zulangue.subtitleOverlay.isPinned"

    static func level(isPinned: Bool) -> NSWindow.Level {
        isPinned ? .floating : .normal
    }

    static func collectionBehavior(isPinned: Bool) -> NSWindow.CollectionBehavior {
        isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
    }
}

@MainActor
final class SubtitleOverlayPresentationSettings: ObservableObject {
    static let shared = SubtitleOverlayPresentationSettings()

    @Published private(set) var isPinned: Bool
    @Published var displayMode: SubtitleOverlayDisplayMode {
        didSet {
            UserDefaults.standard.set(
                displayMode.rawValue,
                forKey: Self.displayModeDefaultsKey
            )
        }
    }

    private static let displayModeDefaultsKey = "zulangue.subtitleOverlay.displayMode"

    private init(defaults: UserDefaults = .standard) {
        if defaults.object(forKey: SubtitleOverlayWindowPolicy.pinnedDefaultsKey) == nil {
            isPinned = true
        } else {
            isPinned = defaults.bool(forKey: SubtitleOverlayWindowPolicy.pinnedDefaultsKey)
        }
        displayMode = defaults.string(forKey: Self.displayModeDefaultsKey)
            .flatMap(SubtitleOverlayDisplayMode.init(rawValue:))
            ?? .conversation
    }

    func togglePinned(defaults: UserDefaults = .standard) {
        isPinned.toggle()
        defaults.set(isPinned, forKey: SubtitleOverlayWindowPolicy.pinnedDefaultsKey)
    }
}

struct SubtitleOverlayView: View {
    @ObservedObject var store: ActiveBilingualTranscriptStore
    @ObservedObject private var coordinator = SubtitleOverlayCoordinator.shared
    @ObservedObject private var presentationSettings = SubtitleOverlayPresentationSettings.shared
    @AppStorage(SubtitleOverlayFontPolicy.defaultsKey)
    private var storedFontSize = SubtitleOverlayFontPolicy.defaultValue

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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "subtitle.overlay.accessibility_label")))
        .accessibilityValue(Text(String(
            format: String(localized: "subtitle.overlay.language_count"),
            store.selectedLanguages.count
        )))
    }

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                captureStatus

                Text(String(localized: "subtitle.overlay.title"))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer(minLength: 16)

                modePicker
                fontControls
                pinButton
                closeButton
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    captureStatus
                    Spacer(minLength: 8)
                    pinButton
                    closeButton
                }
                HStack(spacing: 8) {
                    modePicker
                    Spacer(minLength: 8)
                    fontControls
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .help(String(localized: "subtitle.overlay.move_resize_hint"))
    }

    private var captureStatus: some View {
        CaptureStateLabel(
            captureState: store.captureState,
            remoteHealth: store.remoteHealth,
            projectionState: store.projectionState
        )
    }

    private var pinButton: some View {
        Button {
            presentationSettings.togglePinned()
        } label: {
            Image(systemName: presentationSettings.isPinned ? "pin.fill" : "pin.slash")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(presentationSettings.isPinned ? .accentColor : .secondary)
        .help(String(localized: presentationSettings.isPinned
            ? "subtitle.overlay.unpin"
            : "subtitle.overlay.pin"))
        .accessibilityLabel(Text(String(localized: presentationSettings.isPinned
            ? "subtitle.overlay.unpin"
            : "subtitle.overlay.pin")))
        .accessibilityValue(Text(String(localized: presentationSettings.isPinned
            ? "subtitle.overlay.pinned"
            : "subtitle.overlay.unpinned")))
    }

    private var closeButton: some View {
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

    private var modePicker: some View {
        Picker(
            String(localized: "subtitle.overlay.mode"),
            selection: $presentationSettings.displayMode
        ) {
            Text(String(localized: "subtitle.overlay.mode.conversation"))
                .tag(SubtitleOverlayDisplayMode.conversation)
            Text(String(localized: "subtitle.overlay.mode.audience"))
                .tag(SubtitleOverlayDisplayMode.audience)
        }
        .pickerStyle(.segmented)
        .frame(width: 144)
        .help(String(localized: presentationSettings.displayMode == .conversation
            ? "subtitle.overlay.mode.conversation.help"
            : "subtitle.overlay.mode.audience.help"))
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
            switch presentationSettings.displayMode {
            case .conversation:
                conversationBody(geometry: geometry)
            case .audience:
                audienceBody(geometry: geometry)
            }
        }
    }

    private func conversationBody(geometry: GeometryProxy) -> some View {
        let layout = SubtitleOverlayLayoutPolicy.conversationLayout(
            width: geometry.size.width,
            languageCount: displayLanguages.count,
            fontSize: fontSize
        )

        return VStack(spacing: 0) {
            if layout == .columns {
                languageHeader
                Divider().overlay(Color.white.opacity(0.1))
            }
            conversationTranscript(layout: layout)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    private var languageHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(displayLanguages.enumerated()), id: \.offset) { index, language in
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

                if index < displayLanguages.count - 1 {
                    Divider().overlay(Color.white.opacity(0.1))
                }
            }
        }
        .frame(height: 48)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    @ViewBuilder
    private func conversationTranscript(
        layout: SubtitleOverlayConversationLayout
    ) -> some View {
        if store.isCaptureActive == false {
            emptyState(
                String(localized: "subtitle.overlay.recording_ended"),
                systemImage: "checkmark.circle"
            )
        } else if store.presentedUtterances.isEmpty {
            emptyState(
                String(localized: "subtitle.overlay.waiting"),
                systemImage: "waveform"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.presentedUtterances.suffix(4)) { utterance in
                        conversationRow(utterance, layout: layout)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private func audienceBody(geometry: GeometryProxy) -> some View {
        if store.isCaptureActive == false {
            emptyState(
                String(localized: "subtitle.overlay.recording_ended"),
                systemImage: "checkmark.circle"
            )
        } else if store.presentedUtterances.isEmpty == false {
            let utterances = Array(store.presentedUtterances.suffix(2))
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(utterances.enumerated()), id: \.element.id) {
                        index,
                        utterance in
                        audienceRow(
                            utterance,
                            width: geometry.size.width - 24,
                            isCurrent: index == utterances.count - 1
                        )
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.visible)
        } else {
            emptyState(
                String(localized: "subtitle.overlay.waiting"),
                systemImage: "waveform"
            )
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
    private func conversationRow(
        _ utterance: NotebookCaptureUtteranceDTO,
        layout: SubtitleOverlayConversationLayout
    ) -> some View {
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
            if layout == .columns {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(displayLanes(projection).enumerated()), id: \.offset) {
                        index,
                        lane in
                        conversationLane(lane, showsLanguageHeader: false)
                        if index < displayLanes(projection).count - 1 {
                            Divider().overlay(Color.white.opacity(0.1))
                        }
                    }
                }
                .background(subtitleCardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(displayLanes(projection).enumerated()), id: \.offset) {
                        index,
                        lane in
                        conversationLane(lane, showsLanguageHeader: true)
                        if index < displayLanes(projection).count - 1 {
                            Divider().overlay(Color.white.opacity(0.1))
                        }
                    }
                }
                .background(subtitleCardBackground)
            }
        }
    }

    @ViewBuilder
    private func audienceRow(
        _ utterance: NotebookCaptureUtteranceDTO,
        width: CGFloat,
        isCurrent: Bool
    ) -> some View {
        let projection = store.projection(for: utterance)

        if let pendingLanguage = projection.pendingLanguage {
            statusRow(
                title: String(localized: "capture.transcript.language_pending"),
                detail: pendingLanguage,
                systemImage: "ellipsis",
                color: .secondary
            )
            .opacity(isCurrent ? 1 : 0.72)
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
            .opacity(isCurrent ? 1 : 0.72)
        } else {
            let lanes = displayLanes(projection)
            let columnCount = SubtitleOverlayLayoutPolicy.audienceColumnCount(
                width: width,
                languageCount: lanes.count,
                fontSize: fontSize
            )
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: 8),
                count: columnCount
            )

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                    audienceLane(lane, isCurrent: isCurrent)
                }
            }
        }
    }

    private func conversationLane(
        _ lane: NotebookCaptureLanguageLane,
        showsLanguageHeader: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLanguageHeader {
                languageLabel(lane.language)
            }
            laneContent(lane)
                .font(.system(size: CGFloat(fontSize), weight: .medium))
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: CGFloat(fontSize * 2.35), alignment: .topLeading)
    }

    private func audienceLane(
        _ lane: NotebookCaptureLanguageLane,
        isCurrent: Bool
    ) -> some View {
        let audienceFontSize = isCurrent ? fontSize : max(fontSize * 0.84, 18)

        return VStack(alignment: .leading, spacing: 8) {
            languageLabel(lane.language)
            laneContent(lane)
                .font(.system(size: CGFloat(audienceFontSize), weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(
            maxWidth: .infinity,
            minHeight: CGFloat(fontSize * 2.8),
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isCurrent ? 0.075 : 0.038))
        )
        .opacity(isCurrent ? 1 : 0.74)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func laneContent(_ lane: NotebookCaptureLanguageLane) -> some View {
        if let text = lane.text, text.isEmpty == false {
            Text(text)
                .foregroundColor(.primary)
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

    private func languageLabel(_ language: String) -> some View {
        Text(languageName(language))
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
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

    private var displayLanguages: [String] {
        Array(
            store.selectedLanguages.prefix(
                SubtitleOverlayLayoutPolicy.maximumLanguageCount
            )
        )
    }

    private func displayLanes(
        _ projection: NotebookCaptureLaneProjection
    ) -> [NotebookCaptureLanguageLane] {
        Array(
            projection.lanes.prefix(
                SubtitleOverlayLayoutPolicy.maximumLanguageCount
            )
        )
    }

    private var subtitleCardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.055))
    }

    private func languageName(_ code: String) -> String {
        let normalized = normalizedLanguageCode(code)
        return Locale(identifier: normalized).localizedString(forLanguageCode: normalized)
            ?? Locale.current.localizedString(forLanguageCode: normalized)
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
    private var presentationSettingsCancellable: AnyCancellable?

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
        observePresentationSettings()
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

    private func observePresentationSettings() {
        presentationSettingsCancellable = SubtitleOverlayPresentationSettings.shared.$isPinned
            .removeDuplicates()
            .sink { [weak self] isPinned in
                self?.applyPinnedState(isPinned)
            }
    }

    private func applyPinnedState(_ isPinned: Bool) {
        managedWindow.level = SubtitleOverlayWindowPolicy.level(isPinned: isPinned)
        managedWindow.collectionBehavior =
            SubtitleOverlayWindowPolicy.collectionBehavior(isPinned: isPinned)
        if isPinned, managedWindow.isVisible {
            managedWindow.orderFrontRegardless()
        }
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
