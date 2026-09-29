import AppKit
import Combine
import SwiftUI

/// 看附近一台 ZuTalk 的直播字幕。单独一扇窗:边看边在主窗口里记笔记。
/// 关窗即离开 —— 附近直播不在本机留任何东西。
@MainActor
final class NearbyLiveWindowController: NSWindowController, ManagedWindowController, NSWindowDelegate {
    var windowSurfaceID: WindowSurfaceID { .nearbyLive }
    var managedWindow: NSWindow {
        guard let window else { preconditionFailure("NearbyLiveWindowController.window missing") }
        return window
    }

    init() {
        let spec = WindowSpec.required(.nearbyLive)
        let window = NSWindow(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(WindowSurfaceID.nearbyLive.rawValue)
        window.title = String(localized: "nearby.watch.window_title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureManagedWindow()
        guard !TestEnvironment.isUnitTestMode else { return }
        let hostingView = WindowHosting.makeView(
            rootView: NearbyLiveView(),
            policy: managedWindowSpec.hostingPolicy
        )
        WindowHosting.installPinnedView(hostingView, into: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        NearbyStore.shared.stopWatching()
        WindowCoordinator.shared.didCloseManagedSurface(.nearbyLive)
    }
}

/// 附近直播的字幕:转录稿里已经落定的句子在前,正在说的那一截在后。
/// 可以切换看原文或某一种译文。
struct NearbyLiveView: View {
    @State private var watch: FfiNearbyWatch?
    /// 看哪种语言;nil 是原文。
    @State private var language: String?

    private let tick = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
            Divider()
            if let watch, visibleLines(watch).isEmpty == false {
                lines(watch)
            } else {
                VStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "nearby.watch.waiting"))
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
        }
        .background(Color.bgRoot)
        .onAppear { watch = NearbyStore.shared.watchState() }
        .onReceive(tick) { _ in
            let next = NearbyStore.shared.watchState()
            if next != watch { watch = next }
        }
        .accessibilityIdentifier("nearby.watch")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            if watch?.ended == true {
                Image(systemName: "stop.circle")
                    .foregroundColor(.textTertiary)
            } else {
                PulsingDot(color: .signalGreen, size: 8)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(watch?.title ?? "")
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.md)
            if let languages = watch?.languages, languages.isEmpty == false {
                Picker(String(localized: "nearby.watch.language"), selection: $language) {
                    Text(String(localized: "nearby.watch.original")).tag(String?.none)
                    ForEach(languages, id: \.self) { code in
                        Text(Self.languageName(code)).tag(String?.some(code))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("nearby.watch.language")
            }
        }
    }

    private var subtitle: String {
        guard let watch else { return "" }
        let host = watch.hostName.isEmpty ? String(localized: "settings.devices.unnamed") : watch.hostName
        if watch.ended {
            return String(format: String(localized: "nearby.watch.ended_format"), host)
        }
        return String(format: String(localized: "nearby.watch.from_format"), host)
    }

    private func lines(_ watch: FfiNearbyWatch) -> some View {
        let visible = visibleLines(watch)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(visible, id: \.line.id) { item in
                        row(item.line, text: item.text)
                            .id(item.line.id)
                    }
                }
                .padding(Spacing.lg)
            }
            .onAppear {
                // 等这一轮布局完成再滚,否则长稿停在开头。
                let last = visible.last?.line.id
                DispatchQueue.main.async { proxy.scrollTo(last, anchor: .bottom) }
            }
            .montereyOnChange(of: visible.last?.text) { _, _ in
                proxy.scrollTo(visible.last?.line.id, anchor: .bottom)
            }
        }
    }

    private func row(_ line: FfiNearbyLine, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let speaker = speakerName(line) {
                Text(speaker)
                    .font(.captionMedium)
                    .foregroundColor(.textTertiary)
            }
            Text(text)
                .font(.bodyLG)
                .foregroundColor(line.settled ? .textPrimary : .textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Label(String(localized: "nearby.watch.not_saved"), systemImage: "lock")
                .font(.caption)
                .foregroundColor(.textTertiary)
            Spacer()
            Button(String(localized: "nearby.watch.leave")) {
                NearbyStore.shared.stopWatching()
                WindowCoordinator.shared.window(for: .nearbyLive)?.close()
            }
            .accessibilityIdentifier("nearby.watch.leave")
        }
    }

    private struct VisibleLine {
        let line: FfiNearbyLine
        let text: String
    }

    /// 按选中的语言取每一行的字;这一行没有这种语言就不显示。
    private func visibleLines(_ watch: FfiNearbyWatch) -> [VisibleLine] {
        watch.lines.compactMap { line in
            let text: String
            if let language {
                text = line.translations.first { $0.language == language }?.text ?? ""
            } else {
                text = line.source
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : VisibleLine(line: line, text: trimmed)
        }
    }

    private func speakerName(_ line: FfiNearbyLine) -> String? {
        if let name = line.speaker?.trimmingCharacters(in: .whitespacesAndNewlines), name.isEmpty == false {
            return name
        }
        guard let label = line.speakerLabel, label.isEmpty == false else { return nil }
        return String(format: String(localized: "capture.speaker.fallback_format"), label)
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}
