// OnboardingView.swift
// 首次启动引导 — 认识产品 → 开启实时字幕 → 麦克风 → 完成
// Zulangue onboarding。
// 每一步都由用户主动点击继续，不自动推进。
//
// 布局规范:
// - 顶部 StepIndicator: 产品介绍 > 准备录音
// - 左主内容区 60% : 定位 · 能力 · CTA
// - 右视觉区 40%    : 多语转录 / 录音状态的 blueprint 预览

import SwiftUI
import Combine

// MARK: - Onboarding State

@MainActor
final class OnboardingController: ObservableObject {

    enum Phase: Int, CaseIterable {
        case welcome
        case credential
        case permissions
        case finished

        var stepIndex: Int {
            switch self {
            case .welcome:     return 0
            case .credential:  return 1
            case .permissions: return 2
            case .finished:    return 3
            }
        }
    }

    @Published var phase: Phase = .welcome

    @Published var permissionStatuses: [AppPermission: PermissionStatus] = [:]

    init() {
        refreshPermissions()
    }

    static var shouldShowOnboarding: Bool {
        if TestEnvironment.isUITestMode {
            return false
        }
        let completed = UserDefaults.standard.bool(forKey: "zulangue.onboarding.completed")
        // Onboarding is a first-run explanation, not a recurring permission
        // gate. A local development update can make macOS ask for microphone
        // access again; returning an existing user to Welcome is misleading.
        // The recording path already requests access at the moment it is
        // needed and reports a denied permission without losing local data.
        return !completed
    }

    var allPermissionsGranted: Bool {
        AppPermission.allCases.allSatisfy {
            permissionStatuses[$0] == .granted
        }
    }

    func goToCredential() {
        phase = .credential
    }

    func goToPermissions() {
        phase = .permissions
        refreshPermissions()
    }

    func refreshPermissions() {
        var next: [AppPermission: PermissionStatus] = [:]
        for perm in AppPermission.allCases {
            next[perm] = AppPermissions.status(for: perm)
        }
        permissionStatuses = next
    }

    func requestPermission(_ perm: AppPermission) {
        AppPermissions.request(perm)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func finish() {
        phase = .finished
        UserDefaults.standard.set(true, forKey: "zulangue.onboarding.completed")
    }
}

// MARK: - OnboardingView (shell)

struct OnboardingView: View {
    @StateObject private var controller = OnboardingController()
    @StateObject private var providerViewModel = ProviderConnectionsViewModel()
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            Color.bgRoot.ignoresSafeArea()

            HStack(spacing: 0) {
                // Left: 60% 主内容区
                VStack(spacing: 0) {
                    StepIndicator(currentStep: controller.phase.stepIndex)
                        .padding(.horizontal, 48)
                        .padding(.top, 24)

                    Group {
                        switch controller.phase {
                        case .welcome:
                            WelcomeScreen(onContinue: {
                                withPhaseAnim { controller.goToCredential() }
                            })
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        case .credential:
                            SonioxCredentialScreen(
                                viewModel: providerViewModel,
                                onContinue: {
                                    withPhaseAnim { controller.goToPermissions() }
                                },
                                onBack: { withPhaseAnim { controller.phase = .welcome } }
                            )
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                        case .permissions:
                            PermissionsScreen(
                                controller: controller,
                                onContinue: {
                                    withPhaseAnim {
                                        controller.finish()
                                        onComplete()
                                    }
                                },
                                onBack: { withPhaseAnim { controller.phase = .credential } }
                            )
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                        case .finished:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right: 40% 视觉区 (blueprint wireframe on bpBlueDeep)
                OnboardingVisual(phase: controller.phase)
                    .frame(width: 420)
                    .frame(maxHeight: .infinity)
            }
        }
        .cornerCrosshairs(color: .textTertiary.opacity(0.5), inset: 16, size: 10)
    }

    private func withPhaseAnim(_ action: () -> Void) {
        withAnimation(.easeInOut(duration: 0.35)) { action() }
    }
}

// MARK: - Step Indicator (顶部进度导航)

private struct StepIndicator: View {
    let currentStep: Int

    private let steps: [LocalizedStringKey] = [
        "onboarding.step.signup",
        "onboarding.step.tryout",
        "onboarding.step.setup"
    ]

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            ForEach(0..<steps.count, id: \.self) { i in
                stepLabel(index: i)
                if i < steps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.textTertiary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func stepLabel(index: Int) -> some View {
        let isActive = index == currentStep
        let isDone = index < currentStep
        let color: Color = isActive ? .textPrimary : (isDone ? .textSecondary : .textTertiary)

        VStack(spacing: 6) {
            Text(steps[index])
                .font(.captionMedium)
                .tracking(1.0)
                .foregroundColor(color)
                .textCase(.uppercase)
            Rectangle()
                .fill(isActive ? Color.brandAccent : Color.clear)
                .frame(width: 32, height: 2)
        }
        .animation(.easeInOut(duration: 0.2), value: currentStep)
    }
}

// MARK: - Right Visual (柔和渐变 + 抽象 wireframe)

private struct OnboardingVisual: View {
    let phase: OnboardingController.Phase

    var body: some View {
        ZStack {
            // bp-blue-deep 深蓝底 · 比左主区深一档,视觉上"深入机器内部"
            Color.bgSunken
                .overlay(
                    Rectangle()
                        .fill(Color.borderGhost.opacity(0.4))
                        .frame(width: 0.5),
                    alignment: .leading
                )

            // 蓝图视觉使用的背景网格。
            BlueprintGrid()
                .stroke(Color.borderFaint.opacity(0.15), lineWidth: 0.5)
                .allowsHitTesting(false)

            // 中央产品预览 (白线 on 深蓝)
            visualElement(for: phase)
                .transition(.opacity)

            // 四角 registration marks。
            VStack {
                HStack {
                    CornerCrosshair(color: .textTertiary, size: 10)
                    Spacer()
                    CornerCrosshair(color: .textTertiary, size: 10)
                }
                Spacer()
                HStack {
                    CornerCrosshair(color: .textTertiary, size: 10)
                    Spacer()
                    CornerCrosshair(color: .textTertiary, size: 10)
                }
            }
            .padding(18)
            .allowsHitTesting(false)

            // 右下 cartouche-style 标签
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    phaseCartouche
                        .padding(24)
                }
            }
        }
    }

    @ViewBuilder
    private func visualElement(for phase: OnboardingController.Phase) -> some View {
        switch phase {
        case .welcome:
            TranscriptBlueprintVisual()
        case .credential:
            CredentialBlueprintVisual()
        case .permissions:
            MicrophoneBlueprintVisual()
        case .finished:
            EmptyView()
        }
    }

    private var phaseCartouche: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FIG")
                .font(.captionXs)
                .tracking(0.8)
                .foregroundColor(.textTertiary)
            Text(figNumber)
                .font(.captionMedium)
                .tracking(0.6)
                .foregroundColor(.accentGold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(
            Rectangle()
                .strokeBorder(Color.borderGhost.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var figNumber: String {
        switch phase {
        case .welcome:     return "ZL-LIVE-01"
        case .credential:  return "ZL-KEY-02"
        case .permissions: return "ZL-MIC-03"
        case .finished:    return "ZL-DONE"
        }
    }
}

private struct BlueprintGrid: Shape {
    var spacing: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x: CGFloat = 0
        while x <= rect.width {
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: rect.height))
            x += spacing
        }
        var y: CGFloat = 0
        while y <= rect.height {
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: rect.width, y: y))
            y += spacing
        }
        return p
    }
}

// MARK: - Product blueprint previews

private struct TranscriptBlueprintVisual: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.brandAccent)
                    .frame(width: 7, height: 7)
                Text("onboarding.visual.live")
                    .font(.captionMedium)
                    .tracking(1.0)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("00:12:48")
                    .font(.captionXs)
                    .monospacedDigit()
                    .foregroundColor(.textTertiary)
            }

            Rectangle()
                .fill(Color.borderGhost)
                .frame(height: 0.5)

            transcriptLine(
                speaker: "onboarding.visual.speaker.host",
                language: "onboarding.visual.language.zh",
                widths: [0.84, 0.58]
            )
            transcriptLine(
                speaker: "onboarding.visual.speaker.guest",
                language: "onboarding.visual.language.en",
                widths: [0.72, 0.9]
            )
            transcriptLine(
                speaker: "onboarding.visual.speaker.guest",
                language: "onboarding.visual.language.ja",
                widths: [0.62, 0.76]
            )

            HStack(spacing: 8) {
                languageChip("onboarding.visual.language.zh")
                languageChip("onboarding.visual.language.en")
                languageChip("onboarding.visual.language.ja")
            }
        }
        .padding(24)
        .frame(width: 310)
        .overlay(
            Rectangle()
                .strokeBorder(Color.borderGhost.opacity(0.8), lineWidth: 0.75)
        )
    }

    private func transcriptLine(
        speaker: LocalizedStringKey,
        language: LocalizedStringKey,
        widths: [CGFloat]
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .strokeBorder(Color.textTertiary, lineWidth: 1)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.textSecondary)
                )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(speaker)
                        .font(.captionXs)
                        .foregroundColor(.textSecondary)
                    Text(language)
                        .font(.captionXs)
                        .foregroundColor(.accentGold)
                }
                ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.textTertiary)
                            .frame(width: proxy.size.width * width, height: 4)
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    private func languageChip(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.captionXs)
            .foregroundColor(.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .overlay(
                Capsule()
                    .strokeBorder(Color.borderGhost, lineWidth: 0.75)
            )
    }
}

private struct CredentialBlueprintVisual: View {
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(Color.borderGhost, lineWidth: 0.75)
                    .frame(width: 116, height: 116)
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(.textPrimary)
            }

            HStack(spacing: 9) {
                Circle()
                    .fill(Color.brandAccent)
                    .frame(width: 7, height: 7)
                Text("Soniox")
                    .font(.captionMedium)
                    .foregroundColor(.textPrimary)
                Text("STT-RT-V5")
                    .font(.captionXs)
                    .foregroundColor(.accentGold)
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                Text("onboarding.keys.private_status")
            }
            .font(.captionXs)
            .foregroundColor(.textSecondary)
        }
        .frame(width: 280)
    }
}

private struct MicrophoneBlueprintVisual: View {
    private let barHeights: [CGFloat] = [12, 24, 38, 20, 48, 32, 16, 36, 24, 12]

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .strokeBorder(Color.borderGhost, lineWidth: 0.75)
                    .frame(width: 112, height: 112)
                Circle()
                    .strokeBorder(Color.textTertiary, lineWidth: 1)
                    .frame(width: 80, height: 80)
                Image(systemName: "mic.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(.textPrimary)
            }

            HStack(alignment: .center, spacing: 7) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(index == 4 ? Color.brandAccent : Color.textTertiary)
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 48)

            VStack(spacing: 6) {
                Text("onboarding.visual.microphone.title")
                    .font(.captionMedium)
                    .foregroundColor(.textPrimary)
                Text("onboarding.visual.microphone.detail")
                    .font(.captionXs)
                    .foregroundColor(.textTertiary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(width: 280)
    }
}

// MARK: - Pill Button

struct OnbPillButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    var style: Style = .primary
    var disabled: Bool = false
    let action: () -> Void

    enum Style {
        case primary    // 黑底白字
        case secondary  // 浅灰底黑字
        case ghost      // 透明白底黑字描边
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(fg)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(border, lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1.0)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var fg: Color {
        switch style {
        case .primary:   return .brandAccentForeground
        case .secondary: return Color.textPrimary
        case .ghost:     return Color.textPrimary
        }
    }
    private var bg: Color {
        switch style {
        case .primary:   return hovering ? Color.brandAccentHover : Color.brandAccent
        case .secondary: return hovering ? Color.bgElevated : Color.bgElevated
        case .ghost:     return hovering ? Color.bgElevated : Color.clear
        }
    }
    private var border: Color {
        switch style {
        case .primary, .secondary: return .clear
        case .ghost: return Color.borderGhost
        }
    }
    private var borderWidth: CGFloat {
        style == .ghost ? 1 : 0
    }
}

// MARK: - Small Pill (permission "允许" 按钮)

private struct OnbSmallPill: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    var style: OnbPillButton.Style = .primary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(style == .primary ? .brandAccentForeground : Color.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                style == .primary
                    ? (hovering ? Color.brandAccentHover : Color.brandAccent)
                    : (hovering ? Color.bgElevated : Color.bgElevated)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Welcome Screen

struct WelcomeScreen: View {
    var onContinue: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 48)

            // 品牌标识
            VStack(alignment: .leading, spacing: 6) {
                Text("onboarding.brand.name")
                    .font(.heroSerif)
                    .foregroundColor(Color.line100)
                    .tracking(-0.8)
                Text("onboarding.brand.subtitle")
                    .font(.caption)
                    .foregroundColor(Color.line50)
                    .tracking(1.0)
                    .textCase(.uppercase)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(.easeOut(duration: 0.5).delay(0.05), value: appeared)

            Spacer().frame(height: 24)

            Text("onboarding.brand.tagline")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(.easeOut(duration: 0.5).delay(0.15), value: appeared)

            Spacer().frame(height: 40)

            // 用用户会实际执行的三步解释产品，不要求先理解 Notebook / Session。
            VStack(alignment: .leading, spacing: 12) {
                journeyStep(
                    number: "1",
                    icon: "book.closed.fill",
                    key: "onboarding.welcome.bullet1",
                    delayIdx: 0
                )
                journeyStep(
                    number: "2",
                    icon: "record.circle",
                    key: "onboarding.welcome.bullet2",
                    delayIdx: 1
                )
                journeyStep(
                    number: "3",
                    icon: "text.page",
                    key: "onboarding.welcome.bullet3",
                    delayIdx: 2
                )
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundColor(Color.textTertiary)
                    .frame(width: 18)
                Text("onboarding.welcome.privacy")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.4).delay(0.58), value: appeared)

            Spacer()

            // Primary CTA
            HStack {
                Spacer()
                OnbPillButton(
                    title: "onboarding.welcome.button",
                    style: .primary,
                    action: onContinue
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(.easeOut(duration: 0.4).delay(0.6), value: appeared)
            }

            Spacer().frame(height: 56)
        }
        .padding(.horizontal, 64)
        .onAppear { appeared = true }
    }

    private func journeyStep(
        number: String,
        icon: String,
        key: LocalizedStringKey,
        delayIdx: Int
    ) -> some View {
        HStack(spacing: 14) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.brandAccentForeground)
                .frame(width: 24, height: 24)
                .background(Color.brandAccent)
                .clipShape(Circle())
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.textTertiary)
                .frame(width: 18)
            Text(key)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.textPrimary)
            Spacer()
        }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -12)
        .animation(.easeOut(duration: 0.4).delay(0.3 + Double(delayIdx) * 0.08), value: appeared)
    }
}

// MARK: - Soniox Credential Screen

struct SonioxCredentialScreen: View {
    @ObservedObject var viewModel: ProviderConnectionsViewModel
    @ObservedObject private var verificationStore = ProviderConnectionVerificationStore.shared
    var onContinue: () -> Void
    var onBack: () -> Void

    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var appeared = false

    private var snapshot: ProviderCredentialSnapshot {
        viewModel.snapshot(for: .soniox)
    }

    private var isConfigured: Bool {
        snapshot.isSaved && snapshot.isActive
    }

    private var verificationState: ProviderConnectionVerificationState {
        verificationStore.state(for: .soniox)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 48)

            Text("onboarding.keys.title")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(Color.textPrimary)
                .tracking(-0.5)

            Text("onboarding.keys.subtitle")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Spacer().frame(height: 28)

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Soniox")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Text("onboarding.keys.voice_label")
                            .font(.captionXs)
                            .foregroundColor(.textTertiary)
                    }
                    Spacer()
                    verificationBadge
                }

                if isConfigured {
                    Button {
                        viewModel.verifySavedCredential(for: .soniox)
                    } label: {
                        Label(
                            String(localized: "onboarding.keys.verify_saved"),
                            systemImage: "checkmark.shield"
                        )
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(verificationState == .checking)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "1.circle.fill")
                        Text("onboarding.keys.guide.create")
                        Image(systemName: "arrow.right")
                        Image(systemName: "2.circle.fill")
                        Text("onboarding.keys.guide.copy")
                        Image(systemName: "arrow.right")
                        Image(systemName: "3.circle.fill")
                        Text("onboarding.keys.guide.paste")
                    }
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Link(destination: URL(string: "https://console.soniox.com")!) {
                        Label(
                            String(localized: "onboarding.keys.open_soniox"),
                            systemImage: "arrow.up.right.square"
                        )
                        .frame(minHeight: 32)
                    }
                    .font(.bodyMedium)

                    SecureField(
                        String(localized: "onboarding.keys.paste"),
                        text: $draft
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .disabled(isWorking)
                    .onSubmit(verifyAndSave)

                    Button {
                        verifyAndSave()
                    } label: {
                        Label(
                            String(localized: "onboarding.keys.verify_and_save"),
                            systemImage: "checkmark.shield"
                        )
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isWorking
                            || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                Text("onboarding.keys.soniox.help")
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.signalRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .background(Color.bgSunken.opacity(0.38))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(Color.borderGhost.opacity(0.7), lineWidth: 0.75)
            )

            Spacer()

            HStack(spacing: 12) {
                OnbPillButton(
                    title: "onboarding.common.back",
                    style: .ghost,
                    action: onBack
                )

                Spacer()

                OnbPillButton(
                    title: verificationState.isReady
                        ? "onboarding.keys.continue"
                        : "onboarding.keys.skip",
                    style: verificationState.isReady
                        ? .primary
                        : .ghost,
                    action: onContinue
                )
            }

            Spacer().frame(height: 56)
        }
        .padding(.horizontal, 64)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: appeared)
        .onAppear {
            appeared = true
            viewModel.refresh()
            if isConfigured {
                verificationStore.verifyIfNeeded(
                    account: .soniox,
                    isConfigured: true
                )
            }
        }
        .onDisappear {
            draft = ""
            errorMessage = nil
        }
    }

    @ViewBuilder
    private var verificationBadge: some View {
        switch verificationState {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("onboarding.keys.testing_status"))
        case .ready:
            Label(
                String(localized: "onboarding.keys.connected_status"),
                systemImage: "checkmark.shield.fill"
            )
            .foregroundColor(.signalGreen)
        case .unverified:
            EmptyView()
        default:
            Label(
                ProviderConnectionVerificationFailure(verificationState).localizedDescription,
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundColor(.signalAmber)
            .lineLimit(2)
        }
    }

    private func verifyAndSave() {
        guard !isWorking else { return }
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await viewModel.verifyAndApply(candidate, for: .soniox)
                draft = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Permissions Screen

struct PermissionsScreen: View {
    @ObservedObject var controller: OnboardingController
    var onContinue: () -> Void
    var onBack: () -> Void

    @State private var pollTimer: Timer?
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 48)

            Text("onboarding.permissions.title")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(Color.textPrimary)
                .tracking(-0.5)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(.easeOut(duration: 0.5).delay(0.05), value: appeared)

            Text("onboarding.permissions.subtitle")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.12), value: appeared)

            Spacer().frame(height: 28)

            // 权限卡片列表（只保留 Notebook capture 所需的麦克风权限）。
            VStack(spacing: 14) {
                permissionCard(perm: .microphone, icon: "mic.fill", delayIdx: 0)
            }

            if !controller.allPermissionsGranted {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textTertiary)
                    Text("onboarding.permissions.hint")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color.textTertiary)
                }
                .padding(.top, 16)
                .transition(.opacity)
            }

            Spacer()

            // Navigation
            HStack(spacing: 12) {
                OnbPillButton(
                    title: "onboarding.common.back",
                    style: .ghost,
                    action: onBack
                )

                Spacer()

                OnbPillButton(
                    title: "onboarding.permissions.continue",
                    style: .primary,
                    action: onContinue
                )
                .animation(.easeInOut(duration: 0.25), value: controller.allPermissionsGranted)
                .modifier(ReadyPulseModifier(active: controller.allPermissionsGranted))
            }
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.4).delay(0.55), value: appeared)

            Spacer().frame(height: 56)
        }
        .padding(.horizontal, 64)
        .animation(.easeInOut(duration: 0.25), value: controller.allPermissionsGranted)
        .onAppear {
            appeared = true
            controller.refreshPermissions()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in
                    controller.refreshPermissions()
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zulanguePermissionsMayHaveChanged)) { _ in
            // mic 授权后的副作用通知: 强制刷新以捕获 AX cache invalidate 后的新值
            controller.refreshPermissions()
        }
    }

    @ViewBuilder
    private func permissionCard(perm: AppPermission, icon: String, delayIdx: Int) -> some View {
        let status = controller.permissionStatuses[perm] ?? .notDetermined
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color.textSecondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(nameKey(for: perm))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.textPrimary)
                Text(usageKey(for: perm))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            switch status {
            case .granted:
                ZStack {
                    Circle()
                        .fill(Color.accentGold)
                        .frame(width: 24, height: 24)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .notDetermined, .denied:
                OnbSmallPill(
                    title: status == .denied
                        ? "onboarding.permissions.action.open_settings"
                        : "onboarding.permissions.action.grant",
                    style: .primary
                ) {
                    controller.requestPermission(perm)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Color.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .animation(.easeInOut(duration: 0.3), value: status)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .animation(.easeOut(duration: 0.45).delay(0.25 + Double(delayIdx) * 0.08), value: appeared)
    }

    private func nameKey(for perm: AppPermission) -> LocalizedStringKey {
        switch perm {
        case .microphone: return "onboarding.permissions.mic.name"
        }
    }

    private func usageKey(for perm: AppPermission) -> LocalizedStringKey {
        switch perm {
        case .microphone: return "onboarding.permissions.mic.usage"
        }
    }
}


// MARK: - Ready Pulse Modifier

/// 条件达成时按钮做两次轻微脉冲,引导用户注意"可以继续了"。
/// 动画只运行两个震荡周期。
private struct ReadyPulseModifier: ViewModifier {
    let active: Bool
    @State private var pulseCount = 0
    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: active) { _, newValue in
                guard newValue else {
                    scale = 1.0
                    pulseCount = 0
                    return
                }
                pulse()
            }
    }

    private func pulse() {
        guard pulseCount < 2 else { return }
        pulseCount += 1
        withAnimation(.easeOut(duration: 0.25)) { scale = 1.04 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeIn(duration: 0.25)) { scale = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pulse()
            }
        }
    }
}
