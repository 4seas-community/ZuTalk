import AppKit
import Combine
import SwiftUI

enum SubtitleOverlayFontPolicy {
    static let defaultsKey = "zulangue.subtitleOverlay.fontSize"
    /// The ceiling is sized for a projector canvas read from the back of a
    /// meeting room, not for a laptop panel; the slider spans the full range
    /// continuously and the step only serves the fine-tune buttons.
    static let minimum = 16.0
    static let maximum = 160.0
    static let defaultValue = 30.0
    static let step = 2.0

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
    static let maximumLanguageCount = 3

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

    /// Audience retention is canvas-driven: the row count is whatever the box
    /// affords at the current font size — a squat strip carries a single live
    /// line, a stretched canvas keeps more finished rows on screen. Bounded
    /// above only so an ultra-tall canvas never turns into a scrollback log.
    static func audienceRowCount(height: CGFloat, fontSize: Double) -> Int {
        let estimatedRowHeight = max(CGFloat(fontSize) * 3.2, 1)
        return min(8, max(1, Int(height / estimatedRowHeight)))
    }

    static func minimumColumnWidth(fontSize: Double) -> CGFloat {
        max(240, CGFloat(fontSize * 8))
    }

    static func minimumAudienceTileWidth(fontSize: Double) -> CGFloat {
        max(340, CGFloat(fontSize * 10))
    }
}

/// The overlay paints on an opaque surface instead of a blurred material.
///
/// A translucent window makes the compositor re-run a CoreImage backdrop blur
/// over whatever sits behind it every time the canvas is dirtied. This canvas
/// floats above a live meeting and is dirtied by every transcript revision, so
/// the backdrop never stops changing and the blur can never be cached — the
/// work lands on the WindowServer main thread and stalls the whole display
/// pipeline, not just this app. An opaque fill removes that path entirely.
///
/// Hairlines follow the same constraint: they used to be white-on-material,
/// which disappears against an opaque light-mode surface, so they resolve
/// through the semantic separator color instead.
enum SubtitleOverlayPalette {
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
}

/// Light and dark are an explicit operator choice rather than a mirror of the
/// system appearance: the canvas is read off a projector in a room whose
/// lighting has nothing to do with how this Mac is themed, and a meeting that
/// starts in daylight should not have its subtitles invert at sunset. Dark is
/// the default because a bright panel washes out a projected room.
///
/// The choice resolves through the window's `NSAppearance` rather than by
/// hardcoding colors, so the surface, hairlines, and text all resolve as a
/// matched set — forcing a dark fill while the text stayed system-light would
/// leave the words unreadable, which is the one failure this canvas cannot
/// afford.
enum SubtitleOverlayTheme: String, CaseIterable {
    case dark
    case light

    static let defaultsKey = "zulangue.subtitleOverlay.theme"

    var appearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }

    var toggled: SubtitleOverlayTheme {
        self == .dark ? .light : .dark
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

    @Published var theme: SubtitleOverlayTheme {
        didSet {
            UserDefaults.standard.set(
                theme.rawValue,
                forKey: SubtitleOverlayTheme.defaultsKey
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
            ?? .audience
        theme = defaults.string(forKey: SubtitleOverlayTheme.defaultsKey)
            .flatMap(SubtitleOverlayTheme.init(rawValue:))
            ?? .dark
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
    @State private var isHoveringOverlay = false

    var body: some View {
        subtitleBody
            .frame(minWidth: 560, minHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SubtitleOverlayPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(SubtitleOverlayPalette.hairline, lineWidth: 0.5)
                    )
            )
            .overlay(alignment: .top) { hoverControlBar }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHoveringOverlay = hovering
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(String(localized: "subtitle.overlay.accessibility_label")))
            .accessibilityValue(Text(String(
                format: String(localized: "subtitle.overlay.language_count"),
                store.selectedLanguages.count
            )))
            .environment(\.colorScheme, presentationSettings.theme.colorScheme)
    }

    /// The overlay is a projection canvas in every mode: while it is being
    /// watched rather than operated, the operator chrome stays off-screen
    /// entirely and returns only under the pointer. The window itself remains
    /// movable by its background.
    @ViewBuilder
    private var hoverControlBar: some View {
        if isHoveringOverlay {
            VStack(spacing: 0) {
                controlBar
                Divider().overlay(SubtitleOverlayPalette.hairline)
            }
            .background(SubtitleOverlayPalette.surface)
            .transition(.opacity)
        }
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
                themeButton
                pinButton
                closeButton
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    captureStatus
                    Spacer(minLength: 8)
                    themeButton
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

    private var themeButton: some View {
        Button {
            presentationSettings.theme = presentationSettings.theme.toggled
        } label: {
            Image(systemName: presentationSettings.theme == .dark
                ? "moon.fill"
                : "sun.max.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(String(localized: presentationSettings.theme == .dark
            ? "subtitle.overlay.theme.switch_to_light"
            : "subtitle.overlay.theme.switch_to_dark"))
        .accessibilityLabel(Text(String(localized: presentationSettings.theme == .dark
            ? "subtitle.overlay.theme.switch_to_light"
            : "subtitle.overlay.theme.switch_to_dark")))
        .accessibilityValue(Text(String(localized: presentationSettings.theme == .dark
            ? "subtitle.overlay.theme.dark"
            : "subtitle.overlay.theme.light")))
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
        HStack(spacing: 4) {
            fontButton(
                systemImage: "textformat.size.smaller",
                label: String(localized: "subtitle.overlay.font_smaller"),
                identifier: AccessibilityID.floatingSubtitleFontSmaller,
                disabled: fontSize <= SubtitleOverlayFontPolicy.minimum
            ) {
                storedFontSize = SubtitleOverlayFontPolicy.smaller(than: fontSize)
            }

            Slider(
                value: $storedFontSize,
                in: SubtitleOverlayFontPolicy.minimum...SubtitleOverlayFontPolicy.maximum
            )
            .controlSize(.mini)
            .frame(width: 110)
            .help(String(localized: "subtitle.overlay.font_size"))
            .accessibilityLabel(Text(String(localized: "subtitle.overlay.font_size")))
            .accessibilityValue(Text(verbatim: "\(Int(fontSize))"))

            Text(verbatim: "\(Int(fontSize))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)

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
                Divider().overlay(SubtitleOverlayPalette.hairline)
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
                    Divider().overlay(SubtitleOverlayPalette.hairline)
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

    /// The audience never reads system prose. Silence, session start, and
    /// session end all present the same way — a quiet canvas — and words are
    /// the only thing that ever appears on it.
    ///
    /// Retention favors the present over the past: rows keep their natural
    /// text height and stack from the bottom edge, so a long monologue pushes
    /// finished rows off the top instead of squeezing every row into an equal
    /// slice that truncates the words currently being spoken. When a single
    /// utterance outgrows the whole canvas, the bottom anchor clips its
    /// already-read head and keeps the live tail on screen.
    @ViewBuilder
    private func audienceBody(geometry: GeometryProxy) -> some View {
        let utterances = Array(
            store.presentedUtterances.suffix(
                SubtitleOverlayLayoutPolicy.audienceRowCount(
                    height: geometry.size.height,
                    fontSize: fontSize
                )
            )
        )

        if store.isCaptureActive, utterances.isEmpty == false {
            VStack(spacing: 10) {
                ForEach(utterances) { utterance in
                    audienceRow(utterance, width: geometry.size.width - 24)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .padding(12)
            .animation(.easeOut(duration: 0.22), value: utterances.map(\.id))
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .bottom
            )
            .clipped()
        } else {
            Color.clear
        }
    }

    /// Status prose is operator chrome, not subtitle content: it keeps a fixed
    /// small size no matter how large the audience font is cranked.
    private func emptyState(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 14, weight: .medium))
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
                            Divider().overlay(SubtitleOverlayPalette.hairline)
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
                            Divider().overlay(SubtitleOverlayPalette.hairline)
                        }
                    }
                }
                .background(subtitleCardBackground)
            }
        }
    }

    /// Words-first projection with a quiet promise: lanes carrying words show
    /// them, and a lane whose translation is still on its way holds its place
    /// with a dimmed ellipsis card instead of vanishing — an absent column
    /// reads as "this language is broken", while a placeholder reads as "it's
    /// coming". Lanes that will never fill (unavailable, failed) stay hidden;
    /// the audience is never shown error prose. A line whose language is
    /// still unrouted (pending identification or outside the selection) is
    /// still speech — it shows full-width as plain text, with no label
    /// explaining itself, and the columns catch up silently on the next
    /// revision.
    @ViewBuilder
    private func audienceRow(
        _ utterance: NotebookCaptureUtteranceDTO,
        width: CGFloat
    ) -> some View {
        let projection = store.projection(for: utterance)
        let lanes = displayLanes(projection).filter {
            $0.text?.isEmpty == false || $0.missingLaneState == .waiting
        }

        if lanes.contains(where: { $0.text?.isEmpty == false }) {
            let columnCount = SubtitleOverlayLayoutPolicy.audienceColumnCount(
                width: width,
                languageCount: lanes.count,
                fontSize: fontSize
            )
            let rowStarts = Array(stride(from: 0, to: lanes.count, by: columnCount))

            // Lane cards match the tallest lane in their row, and the row
            // itself takes whatever height its text needs — no line is ever
            // cut to fit a pre-sliced tile.
            VStack(spacing: 8) {
                ForEach(rowStarts, id: \.self) { start in
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(
                            Array(lanes[start..<min(start + columnCount, lanes.count)].enumerated()),
                            id: \.offset
                        ) { _, lane in
                            if lane.text?.isEmpty == false {
                                audienceLane(lane)
                            } else {
                                audienceWaitingLane(lane)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let unroutedText = projection.pendingLanguage
            ?? projection.unselectedLanguageText,
            unroutedText.isEmpty == false {
            audiencePlainText(unroutedText)
        }
    }

    private func audiencePlainText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(subtitleCardBackground)
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

    /// One lane, words only: no per-row language caption, no line cap, no
    /// dimming. The row being read is usually the one whose translation just
    /// filled in, so every visible row keeps full size and full brightness,
    /// and a long sentence wraps instead of scaling away its tail.
    ///
    /// Lane text anchors to the bottom of its card: languages run different
    /// lengths, so a row taller than the canvas clips through its top edge —
    /// a top-anchored short lane would sit entirely inside that clipped band
    /// and vanish, while bottom-anchored lanes all keep their live tail in
    /// the visible bottom region.
    private func audienceLane(_ lane: NotebookCaptureLanguageLane) -> some View {
        Text(lane.text ?? "")
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundColor(.primary)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.18), value: lane.text)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(subtitleCardBackground)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(languageName(lane.language)))
            .accessibilityValue(Text(lane.text ?? ""))
    }

    /// A lane whose translation is still in flight keeps its column with a
    /// dimmed ellipsis — never prose, so the quiet-canvas rule holds. The
    /// ellipsis scales with the subtitle font so the placeholder reads at the
    /// same distance the words will.
    private func audienceWaitingLane(_ lane: NotebookCaptureLanguageLane) -> some View {
        Image(systemName: "ellipsis")
            .font(.system(size: max(CGFloat(fontSize) * 0.55, 12), weight: .semibold))
            .foregroundColor(.secondary.opacity(0.55))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(
                maxWidth: .infinity,
                minHeight: CGFloat(fontSize) * 1.6,
                maxHeight: .infinity,
                alignment: .bottomLeading
            )
            .background(subtitleCardBackground)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(languageName(lane.language)))
            .accessibilityValue(Text(String(
                format: String(localized: "capture.transcript.waiting_lane"),
                displayLanguageCode(lane.language)
            )))
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
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
        } else if lane.missingLaneState == .failed {
            Label(
                String(
                    format: String(localized: "capture.transcript.failed_lane"),
                    displayLanguageCode(lane.language)
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 12, weight: .medium))
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
    private var themeCancellable: AnyCancellable?

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
        themeCancellable = SubtitleOverlayPresentationSettings.shared.$theme
            .removeDuplicates()
            .sink { [weak self] theme in
                self?.applyTheme(theme)
            }
    }

    /// Pinning the appearance to the window rather than to the hosting view
    /// keeps the panel's own chrome — the resize edges and the shadow AppKit
    /// draws outside the SwiftUI content — in the same theme as the canvas.
    private func applyTheme(_ theme: SubtitleOverlayTheme) {
        managedWindow.appearance = theme.appearance
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
