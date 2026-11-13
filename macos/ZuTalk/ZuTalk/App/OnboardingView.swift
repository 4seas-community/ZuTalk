// OnboardingView.swift
// 首次启动引导 — 认识产品 → 出字要用到的 → 麦克风 → 完成
// ZuTalk onboarding。
// 每一步都由用户主动点击继续，不自动推进。
//
// 第二步以前一上来就要一把 Soniox API 密钥。大多数人手里有的是邀请码,而邀请码
// 在这里根本填不了,只能先跳过、再去设置里找。现在第二步的主栏是邀请码,下面
// 两个安静的选择:用自己的密钥,或者先跳过、只录音。登录不在这里:它今天给
// 一个普通人的东西不是开始录音所必需的,而且在设置里一步就到。
//
// 布局规范:
// - 顶部 StepIndicator: 认识 ZuTalk > 出字 > 麦克风
// - 左主内容区 60% : 定位 · 能力 · CTA
// - 右视觉区 40%    : 多语转录 / 录音状态的 blueprint 预览

import SwiftUI
import Combine

// MARK: - Onboarding State

@MainActor
final class OnboardingController: ObservableObject {

    enum Phase: Int, CaseIterable {
        case welcome
        /// 「出字要用到的」:邀请码,或自己的密钥,或先跳过。
        case liveText
        case permissions
        case finished

        var stepIndex: Int {
            switch self {
            case .welcome:     return 0
            case .liveText:    return 1
            case .permissions: return 2
            case .finished:    return 3
            }
        }
    }

    @Published var phase: Phase = .welcome

    @Published var permissionStatuses: [AppPermission: PermissionStatus] = [:]

    static let completedKey = "zutalk.onboarding.completed"

    /// Where "onboarding is done" is remembered. The app uses the standard
    /// domain; tests pass a suite of their own, because under test the
    /// standard domain is the installed app's real preferences.
    private let defaults: UserDefaults
    private let openSystemSettings: @MainActor (AppPermission) -> Void

    init(
        defaults: UserDefaults = .standard,
        openSystemSettings: @escaping @MainActor (AppPermission) -> Void = {
            AppPermissions.openSystemSettings(for: $0)
        }
    ) {
        self.defaults = defaults
        self.openSystemSettings = openSystemSettings
        refreshPermissions()
    }

    static var shouldShowOnboarding: Bool {
        shouldShowOnboarding(defaults: .standard)
    }

    static func shouldShowOnboarding(defaults: UserDefaults) -> Bool {
        if TestEnvironment.isUITestMode {
            return false
        }
        let completed = defaults.bool(forKey: completedKey)
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

    func goToLiveText() {
        phase = .liveText
    }

    func goToPermissions() {
        phase = .permissions
        refreshPermissions()
    }

    /// 「先跳过，只录音」。什么都不用记:没有邀请码也没有密钥的时候,录音本来
    /// 就只录音;以后哪天有了,边录边出字的默认值自己会跟上
    /// (`CaptureCommandCenter`)。
    func skipLiveText() {
        goToPermissions()
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

    /// 权限卡片上那个按钮做的事。还没问过就问;已经拒绝过,系统不会再弹第二次,
    /// 再「请求」一遍什么也不会发生 —— 这时候只能带人去系统设置里打开。按钮
    /// 以前写着「打开系统设置」,按下去却是再请求一遍。
    func resolvePermission(_ perm: AppPermission) {
        switch permissionStatuses[perm] ?? .notDetermined {
        case .granted:
            break
        case .notDetermined:
            requestPermission(perm)
        case .denied:
            openSystemSettings(perm)
        }
    }

    func finish() {
        phase = .finished
        defaults.set(true, forKey: Self.completedKey)
    }
}

/// 第二步摆出来的是哪一样。一次只摆一样:主栏是邀请码,选了「用自己的密钥」
/// 才换成密钥那一面。
enum OnboardingLiveTextMode: Equatable {
    case inviteCode
    case ownKey

    /// 头一回来的人看到的是邀请码。从设置里再走一遍的人,如果本来用的就是
    /// 自己的密钥、没有邀请码,直接看到密钥那一面,不用再点一下。
    static func initial(inviteActive: Bool, hasOwnKey: Bool) -> OnboardingLiveTextMode {
        hasOwnKey && inviteActive == false ? .ownKey : .inviteCode
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
                                withPhaseAnim { controller.goToLiveText() }
                            })
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        case .liveText:
                            LiveTextSetupScreen(
                                viewModel: providerViewModel,
                                onContinue: {
                                    withPhaseAnim { controller.goToPermissions() }
                                },
                                onSkip: {
                                    withPhaseAnim { controller.skipLiveText() }
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
                                onBack: { withPhaseAnim { controller.phase = .liveText } }
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
        .overlay(alignment: .topTrailing) {
            // Opened again from Settings: nothing here is required any more,
            // so there is a way out at every step.
            if hasCompletedBefore {
                Button(String(localized: "common.close")) {
                    onComplete()
                }
                .keyboardShortcut(.cancelAction)
                .padding(Spacing.lg)
                .accessibilityIdentifier("onboarding.close")
            }
        }
    }

    private let hasCompletedBefore = UserDefaults.standard.bool(forKey: OnboardingController.completedKey)

    private func withPhaseAnim(_ action: () -> Void) {
        withAnimation(.easeInOut(duration: 0.35)) { action() }
    }
}

// MARK: - Step Indicator (顶部进度导航)

private struct StepIndicator: View {
    let currentStep: Int

    private let steps: [LocalizedStringKey] = [
        "onboarding.step.signup",
        "onboarding.step.live_text",
        "onboarding.step.microphone"
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
        }
    }

    @ViewBuilder
    private func visualElement(for phase: OnboardingController.Phase) -> some View {
        switch phase {
        case .welcome:
            TranscriptBlueprintVisual()
        case .liveText:
            LiveTextBlueprintVisual()
        case .permissions:
            MicrophoneBlueprintVisual()
        case .finished:
            EmptyView()
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

/// 第二步的图:一句原文、一句译文,正在往外出。不写供应商和模型的名字 ——
/// 这一步的主角是邀请码,用邀请码的人不需要认识它们。
private struct LiveTextBlueprintVisual: View {
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(Color.borderGhost, lineWidth: 0.75)
                    .frame(width: 116, height: 116)
                Image(systemName: "captions.bubble")
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(.textPrimary)
            }

            VStack(alignment: .leading, spacing: 9) {
                textBar(width: 150, color: .textTertiary)
                textBar(width: 112, color: .accentGold)
            }

            HStack(spacing: 9) {
                Circle()
                    .fill(Color.brandAccent)
                    .frame(width: 7, height: 7)
                Text("onboarding.live_text.visual")
                    .font(.captionMedium)
                    .foregroundColor(.textPrimary)
            }
        }
        .frame(width: 280)
    }

    private func textBar(width: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: 4)
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
        .opacity(disabled && style != .primary ? 0.35 : 1.0)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// 还不能点的主按钮换成灰底灰字,不是把绿底调淡:调淡以后白字压在浅绿上,
    /// 读不出按钮上写的是什么,人不知道自己在等的是哪一步。
    private var isInactivePrimary: Bool {
        disabled && style == .primary
    }

    private var fg: Color {
        if isInactivePrimary { return Color.textTertiary }
        switch style {
        case .primary:   return .brandAccentForeground
        case .secondary: return Color.textPrimary
        case .ghost:     return Color.textPrimary
        }
    }
    private var bg: Color {
        if isInactivePrimary { return Color.bgElevated }
        switch style {
        case .primary:   return hovering ? Color.brandAccentHover : Color.brandAccent
        case .secondary: return hovering ? Color.bgElevated : Color.bgElevated
        case .ghost:     return hovering ? Color.bgElevated : Color.clear
        }
    }
    private var border: Color {
        if isInactivePrimary { return Color.borderGhost }
        switch style {
        case .primary, .secondary: return .clear
        case .ghost: return Color.borderGhost
        }
    }
    private var borderWidth: CGFloat {
        style == .ghost || isInactivePrimary ? 1 : 0
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
                    icon: "record.circle",
                    key: "onboarding.welcome.bullet1",
                    delayIdx: 0
                )
                journeyStep(
                    number: "2",
                    icon: "bookmark",
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
                Text("onboarding.welcome.privacy_plain")
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

// MARK: - 出字要用到的

/// 第二步。主栏是邀请码;下面两个安静的选择:用自己的密钥(换成密钥那一面),
/// 或者先跳过、只录音。「继续」要等真的能出字了才亮,所以跳过是人自己选的,
/// 不是按了「继续」才发现什么都没设。
struct LiveTextSetupScreen: View {
    @ObservedObject var viewModel: ProviderConnectionsViewModel
    @ObservedObject private var invite = CommunityInviteSession.shared
    var onContinue: () -> Void
    var onSkip: () -> Void
    var onBack: () -> Void

    @State private var mode: OnboardingLiveTextMode = .inviteCode
    @State private var code = ""
    @State private var appeared = false

    /// 现在靠什么出字。密钥那一面存上以后 `viewModel` 会变,这里跟着重算。
    private var source: LiveTextSource {
        LiveTextSource.resolve(
            inviteActive: invite.isActive,
            inviteEnabled: invite.isEnabled,
            remainingSeconds: invite.remainingSeconds,
            laneCount: invite.plannedLaneCount,
            hasOwnKey: viewModel.snapshot(for: .soniox).isActive
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 48)

            Text("onboarding.live_text.title")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(Color.textPrimary)
                .tracking(-0.5)

            Text("onboarding.live_text.subtitle")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Spacer().frame(height: 28)

            switch mode {
            case .inviteCode:
                inviteBox
            case .ownKey:
                OwnSonioxKeyBox(viewModel: viewModel)
            }

            quietChoices
                .padding(.top, 16)

            Spacer()

            HStack(spacing: 12) {
                OnbPillButton(
                    title: "onboarding.common.back",
                    style: .ghost,
                    action: onBack
                )

                Spacer()

                OnbPillButton(
                    title: "onboarding.keys.continue",
                    style: .primary,
                    disabled: source.powersLiveText == false,
                    action: onContinue
                )
                .accessibilityIdentifier("onboarding.live-text.continue")
            }

            Spacer().frame(height: 56)
        }
        .padding(.horizontal, 64)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: appeared)
        .onAppear {
            appeared = true
            viewModel.refresh()
            mode = .initial(
                inviteActive: invite.isActive,
                hasOwnKey: viewModel.snapshot(for: .soniox).isActive
            )
        }
        .onDisappear {
            code = ""
        }
        // 再走一遍引导的人已经有邀请码:把还能录多久问回来,那一句才报得出数。
        .task { await invite.refreshQuota() }
    }

    // MARK: 邀请码

    private var inviteBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "settings.live_text.invite_field_label"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.textPrimary)

            HStack(spacing: 10) {
                TextField(
                    String(localized: "community_invite.placeholder"),
                    text: $code
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .disabled(invite.isWorking)
                .onSubmit(redeem)
                .accessibilityLabel(String(localized: "settings.live_text.invite_field_label"))
                .accessibilityIdentifier("onboarding.live-text.invite-code")

                // 栏和按钮用同一个尺寸:按钮比栏高出一倍的话,人先看到的是按钮。
                Button {
                    redeem()
                } label: {
                    if invite.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(localized: "onboarding.live_text.redeem"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    invite.isWorking
                        || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("onboarding.live-text.redeem")
            }

            inviteStatus
        }
        .padding(20)
        .background(Color.bgSunken.opacity(0.38))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.borderGhost.opacity(0.7), lineWidth: 0.75)
        )
    }

    /// 栏下面那一句:出了错说错在哪;已经能出字了,说靠的是什么、还能录多久。
    @ViewBuilder
    private var inviteStatus: some View {
        if let error = invite.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.signalAmber)
                .fixedSize(horizontal: false, vertical: true)
        } else if source != .nothing {
            Label(
                source.sentence,
                systemImage: source.powersLiveText ? "checkmark.circle.fill" : source.symbol
            )
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(source.powersLiveText ? .signalGreen : .signalAmber)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("onboarding.live-text.status")
        }
    }

    // MARK: 两个安静的选择

    /// 上下摆,不并排:窗口窄、字又长的语言里,并排的两句会各自折成两行。
    private var quietChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch mode {
            case .inviteCode:
                // 供应商的名字只在这一处和「设置 › 高级」出现:要用自己密钥的人
                // 得知道是哪家的密钥。名字从账户来,不在这里写死。
                Button(String(
                    format: String(localized: "onboarding.live_text.use_own_key_format"),
                    ProviderCredentialAccount.soniox.displayName
                )) {
                    mode = .ownKey
                }
                .accessibilityIdentifier("onboarding.live-text.use-own-key")
            case .ownKey:
                Button(String(localized: "onboarding.live_text.use_invite")) {
                    mode = .inviteCode
                }
                .accessibilityIdentifier("onboarding.live-text.use-invite")
            }

            if source.powersLiveText == false {
                Button(String(localized: "onboarding.live_text.skip"), action: onSkip)
                    .accessibilityIdentifier("onboarding.live-text.skip")
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 13, weight: .regular))
        .multilineTextAlignment(.leading)
    }

    private func redeem() {
        guard invite.isWorking == false else { return }
        Task {
            await invite.redeem(code)
            if invite.isActive, invite.errorMessage == nil {
                code = ""
            }
        }
    }
}

// MARK: - 自己的 Soniox 密钥

/// 第二步里选了「用自己的密钥」以后换上来的那一面:去哪拿、粘贴、验证并保存。
/// 密钥仍然只经 `ProviderConnectionsViewModel` 进凭据会话,验证通过才存。
private struct OwnSonioxKeyBox: View {
    @ObservedObject var viewModel: ProviderConnectionsViewModel
    @ObservedObject private var verificationStore = ProviderConnectionVerificationStore.shared

    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

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
        .onAppear {
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
                ProviderConnectionVerificationFailure(verificationState, account: .soniox)
                    .localizedDescription,
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
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textTertiary)
                    // 拒绝过的人按了按钮会被带到系统设置:说清楚去那里做什么、
                    // 做完回哪。
                    Text(isDenied
                        ? "onboarding.permissions.denied_hint"
                        : "onboarding.permissions.hint")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
        .onReceive(NotificationCenter.default.publisher(for: .zutalkPermissionsMayHaveChanged)) { _ in
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
                        ? "onboarding.permissions.action.open_system_settings"
                        : "onboarding.permissions.action.grant",
                    style: .primary
                ) {
                    controller.resolvePermission(perm)
                }
                .accessibilityIdentifier("onboarding.permissions.action")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .surfaceCard(fill: Color.bgElevated, cornerRadius: Radius.sm)
        .animation(.easeInOut(duration: 0.3), value: status)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .animation(.easeOut(duration: 0.45).delay(0.25 + Double(delayIdx) * 0.08), value: appeared)
    }

    private var isDenied: Bool {
        AppPermission.allCases.contains { controller.permissionStatuses[$0] == .denied }
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
            .montereyOnChange(of: active) { _, newValue in
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
