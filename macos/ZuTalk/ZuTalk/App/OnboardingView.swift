// OnboardingView.swift
// 首次启动 — 三步:认识 ZuTalk → 出字 → 麦克风。
// 每一步都由用户主动点击继续，不自动推进。
//
// 每一步是一个标题和它的控件,没有说明句(docs/product/interface-layers.md
// 「界面怎么写」):
//   1. ZuTalk:一句话,和「开始」;
//   2. 出字:邀请码那一栏和「启用」;下面两颗安静的胶囊 ——「用自己的密钥」
//      (换成密钥那一面)和「先跳过，只录音」;
//   3. 麦克风:「允许」;拒绝过的人看到那一句和「打开系统设置」。
// 原来铺在页面上的句子都还在:怎么录的那三条在「开始」的提示里;录音存在哪、
// 声音什么时候会发出去,在「出字」标题旁边的 ⓘ 里;密钥未加密保存、验证时不
// 上传录音,在密钥那一栏旁边的 ⓘ 里。
//
// 第二步的主栏是邀请码,不是密钥:大多数人手里有的是邀请码。登录不在这里:
// 它今天给一个普通人的东西不是开始录音所必需的,而且在设置里一步就到。
//
// 布局:
// - 顶上三个点:走到第几步
// - 左:标题和控件;最下面一行是返回和这一步的主按钮
// - 右:一幅没有字的蓝图(出字的样子、麦克风),只是装饰

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
    /// What the system says about a permission. The app asks the system; a
    /// test answers for it, to look at "denied" without denying anything.
    private let permissionStatus: @MainActor (AppPermission) -> PermissionStatus

    /// Whether this is a walk through it again, opened from Settings: then
    /// nothing here is required and every step offers a way out.
    let hasCompletedBefore: Bool

    init(
        defaults: UserDefaults = .standard,
        openSystemSettings: @escaping @MainActor (AppPermission) -> Void = {
            AppPermissions.openSystemSettings(for: $0)
        },
        permissionStatus: @escaping @MainActor (AppPermission) -> PermissionStatus = {
            AppPermissions.status(for: $0)
        }
    ) {
        self.defaults = defaults
        self.openSystemSettings = openSystemSettings
        self.permissionStatus = permissionStatus
        hasCompletedBefore = defaults.bool(forKey: Self.completedKey)
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
            next[perm] = permissionStatus(perm)
        }
        permissionStatuses = next
    }

    func requestPermission(_ perm: AppPermission) {
        AppPermissions.request(perm)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshPermissions()
        }
    }

    /// 麦克风那一步的按钮做的事。还没问过就问;已经拒绝过,系统不会再弹第二次,
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

/// 首次启动里的尺寸。标题大,控件比设置里的高一档:这一屏只有一两样东西。
private enum OnboardingMetrics {
    static let controlHeight: CGFloat = 40
    static let titleFont = Font.system(size: 34, weight: .bold)
    static let controlFont = Font.system(size: 14, weight: .semibold)
    static let fieldFont = Font.bodyLG
    /// Left and right of each step's content.
    static let gutter: CGFloat = Spacing.xxl
    /// The decorative panel: this share of the window, within these bounds.
    static let visualShare: CGFloat = 0.36
    static let visualMinWidth: CGFloat = 280
    static let visualMaxWidth: CGFloat = 420
}

// MARK: - OnboardingView (shell)

struct OnboardingView: View {
    @StateObject private var controller: OnboardingController
    @StateObject private var providerViewModel = ProviderConnectionsViewModel()
    var onComplete: () -> Void

    /// The app passes no controller and gets the real one. A test passes one
    /// that keeps "done" to itself and answers for the microphone.
    init(controller: OnboardingController? = nil, onComplete: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: controller ?? OnboardingController())
        self.onComplete = onComplete
    }

    var body: some View {
        GeometryReader { window in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    StepIndicator(currentStep: controller.phase.stepIndex)
                        .padding(.top, Spacing.lg)

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

                // 右:没有字的蓝图。窗口窄的时候它先让出宽度。
                OnboardingVisual(phase: controller.phase)
                    .frame(width: min(
                        OnboardingMetrics.visualMaxWidth,
                        max(OnboardingMetrics.visualMinWidth, window.size.width * OnboardingMetrics.visualShare)
                    ))
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .background(Color.bgRoot.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            // Opened again from Settings: nothing here is required any more,
            // so there is a way out at every step.
            if controller.hasCompletedBefore {
                ActionPill(
                    String(localized: "common.close"),
                    systemImage: "xmark",
                    style: .quiet
                ) {
                    onComplete()
                }
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.md)
                .accessibilityIdentifier("onboarding.close")
            }
        }
    }

    private func withPhaseAnim(_ action: () -> Void) {
        withAnimation(.easeInOut(duration: 0.35)) { action() }
    }
}

// MARK: - Step Indicator (顶上三个点)

/// 走到第几步:三个点,当前那个长一些。每一步的名字就是它自己的大标题,这里
/// 不再写一遍。
private struct StepIndicator: View {
    let currentStep: Int

    private static let stepCount = 3

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(0..<Self.stepCount, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: index == currentStep ? 24 : 8, height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(min(currentStep + 1, Self.stepCount)) / \(Self.stepCount)"))
    }

    private func color(for index: Int) -> Color {
        if index == currentStep { return .brandAccent }
        return index < currentStep ? .textSecondary : .borderActive
    }
}

// MARK: - Right Visual (没有字的蓝图)

private struct OnboardingVisual: View {
    let phase: OnboardingController.Phase

    var body: some View {
        ZStack {
            // 比左边深一档的底。
            Color.bgSunken
                .overlay(
                    Rectangle()
                        .fill(Color.borderGhost.opacity(0.4))
                        .frame(width: Stroke.hairline),
                    alignment: .leading
                )

            BlueprintGrid()
                .stroke(Color.borderFaint.opacity(0.15), lineWidth: Stroke.hairline)
                .allowsHitTesting(false)

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
            .padding(Spacing.md)
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
    var spacing: CGFloat = Spacing.grid

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

// MARK: - 蓝图:只有线条,没有字

/// 一条用线代替的字。
private func blueprintBar(width: CGFloat, color: Color) -> some View {
    Capsule()
        .fill(color)
        .frame(width: width, height: 4)
}

/// 第一步的图:几个人轮流说,每人一句原文(灰)、一句译文(金)。
private struct TranscriptBlueprintVisual: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(Color.brandAccent)
                    .frame(width: 7, height: 7)
                blueprintBar(width: 56, color: .textSecondary)
                Spacer()
            }

            Rectangle()
                .fill(Color.borderGhost)
                .frame(height: Stroke.hairline)

            transcriptLine(widths: [150, 104])
            transcriptLine(widths: [128, 162])
            transcriptLine(widths: [112, 136])
        }
        .padding(Spacing.lg)
        .frame(width: 256)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.8), lineWidth: 0.75)
        )
    }

    private func transcriptLine(widths: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: Spacing.xsm) {
            Circle()
                .strokeBorder(Color.textTertiary, lineWidth: 1)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.textSecondary)
                )

            VStack(alignment: .leading, spacing: Spacing.sm) {
                blueprintBar(width: widths[0], color: .textTertiary)
                blueprintBar(width: widths[1], color: .accentGold)
            }
            .padding(.top, Spacing.sm)
        }
    }
}

/// 第二步的图:一句原文、一句译文,正在往外出。
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
                blueprintBar(width: 150, color: .textTertiary)
                blueprintBar(width: 112, color: .accentGold)
            }
        }
        .frame(width: 240)
    }
}

private struct MicrophoneBlueprintVisual: View {
    private let barHeights: [CGFloat] = [12, 24, 38, 20, 48, 32, 16, 36, 24, 12]

    var body: some View {
        VStack(spacing: Spacing.lg) {
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
        }
        .frame(width: 240)
    }
}

// MARK: - 这一步的主按钮

/// 首次启动里的大按钮。每一步只有一个实心的(`primary`):那一步现在该按的
/// 那一个;别的是描边的(`ghost`)。
struct OnbPillButton: View {
    let title: String
    var icon: String? = nil
    var style: Style = .primary
    var disabled: Bool = false
    var help: String? = nil
    let action: () -> Void

    enum Style {
        case primary    // 实心
        case ghost      // 描边
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(OnboardingMetrics.controlFont)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(fg)
            .padding(.horizontal, Spacing.lg)
            .frame(height: OnboardingMetrics.controlHeight)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(border, lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .opacity(disabled && style != .primary ? 0.35 : 1.0)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help ?? "")
        .accessibilityHint(Text(help ?? ""))
    }

    /// 还不能点的主按钮换成灰底灰字,不是把绿底调淡:调淡以后白字压在浅绿上,
    /// 读不出按钮上写的是什么,人不知道自己在等的是哪一步。
    private var isInactivePrimary: Bool {
        disabled && style == .primary
    }

    private var fg: Color {
        if isInactivePrimary { return Color.textTertiary }
        switch style {
        case .primary: return .brandAccentForeground
        case .ghost:   return Color.textPrimary
        }
    }
    private var bg: Color {
        if isInactivePrimary { return Color.bgElevated }
        switch style {
        case .primary: return hovering ? Color.brandAccentHover : Color.brandAccent
        case .ghost:   return hovering ? Color.bgElevated : Color.clear
        }
    }
    private var border: Color {
        if isInactivePrimary { return Color.borderGhost }
        switch style {
        case .primary: return .clear
        case .ghost:   return Color.borderActive
        }
    }
    private var borderWidth: CGFloat {
        style == .ghost || isInactivePrimary ? Stroke.thin : 0
    }
}

/// 首次启动里的一栏输入:和大按钮一样高。
private struct OnboardingField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(OnboardingMetrics.fieldFont)
        .foregroundColor(.textPrimary)
        .padding(.horizontal, Spacing.xsm)
        .frame(height: OnboardingMetrics.controlHeight)
        .background(Color.bgRoot)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderActive, lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// 一步的骨架:标题(旁边可以有一个 ⓘ)、控件、最下面一行返回和主按钮。
private struct OnboardingStep<Controls: View, Footer: View>: View {
    let title: String
    var info: String?
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: Spacing.lg)
                .frame(maxHeight: Spacing.xxl * 2)

            HStack(alignment: .center, spacing: Spacing.xs) {
                Text(title)
                    .font(OnboardingMetrics.titleFont)
                    .foregroundColor(Color.textPrimary)
                    .tracking(-0.5)
                    .accessibilityAddTraits(.isHeader)
                if let info {
                    InfoButton(info, accessibilityLabel: title)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                controls()
            }
            .padding(.top, Spacing.lg)

            Spacer(minLength: Spacing.lg)

            HStack(spacing: Spacing.xsm) {
                footer()
            }
            .padding(.bottom, Spacing.xxl)
        }
        .padding(.horizontal, OnboardingMetrics.gutter)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - 第一步:ZuTalk

/// 名字、一句话、「开始」。怎么录的那三条(选语言按开始、⌃⌥S 标记、录完在
/// 一处看)在「开始」的提示里。
struct WelcomeScreen: View {
    var onContinue: () -> Void
    @State private var appeared = false

    private var howItGoes: String {
        [
            "onboarding.welcome.bullet1",
            "onboarding.welcome.bullet2",
            "onboarding.welcome.bullet3",
        ]
        .map { String(localized: String.LocalizationValue($0)) }
        .joined(separator: "\n")
    }

    var body: some View {
        OnboardingStep(title: String(localized: "onboarding.brand.name")) {
            Text(String(localized: "onboarding.brand.tagline"))
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Spacer()
            OnbPillButton(
                title: String(localized: "onboarding.start"),
                style: .primary,
                help: howItGoes,
                action: onContinue
            )
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.welcome.start")
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: appeared)
        .onAppear { appeared = true }
    }
}

// MARK: - 第二步:出字

/// 主栏是邀请码;下面两颗安静的胶囊:用自己的密钥(换成密钥那一面),或者
/// 先跳过、只录音。「继续」要等真的能出字了才亮,所以跳过是人自己选的,不是
/// 按了「继续」才发现什么都没设。这一步只有一个实心按钮:还不能出字的时候
/// 是「启用」(或「验证并保存」),能出字了是「继续」。
struct LiveTextSetupScreen: View {
    @ObservedObject var viewModel: ProviderConnectionsViewModel
    @ObservedObject private var invite = CommunityInviteSession.shared
    @Environment(\.settingsFixture) private var fixture
    var onContinue: () -> Void
    var onSkip: () -> Void
    var onBack: () -> Void

    @State private var mode: OnboardingLiveTextMode = .inviteCode
    @State private var code = ""
    @State private var appeared = false

    /// 现在靠什么出字。密钥那一面存上以后 `viewModel` 会变,这里跟着重算。
    private var source: LiveTextSource {
        if let fixture { return fixture.liveText.source }
        return LiveTextSource.resolve(
            inviteActive: invite.isActive,
            inviteEnabled: invite.isEnabled,
            remainingSeconds: invite.remainingSeconds,
            laneCount: invite.plannedLaneCount,
            hasOwnKey: viewModel.snapshot(for: .soniox).isActive
        )
    }

    private var isWorking: Bool { fixture?.liveText.isWorking ?? invite.isWorking }
    private var errorMessage: String? {
        if let fixture { return fixture.liveText.errorMessage }
        return invite.errorMessage
    }

    var body: some View {
        OnboardingStep(
            title: String(localized: "onboarding.step.live_text"),
            // 录音存在哪、声音什么时候会发出去:必须让人读得到。
            info: String(localized: "onboarding.welcome.privacy_plain")
        ) {
            switch mode {
            case .inviteCode:
                inviteEntry
            case .ownKey:
                OwnSonioxKeyEntry(viewModel: viewModel, isPrimary: source.powersLiveText == false)
            }

            quietChoices
        } footer: {
            OnbPillButton(
                title: String(localized: "onboarding.back"),
                icon: "arrow.left",
                style: .ghost,
                action: onBack
            )

            Spacer()

            OnbPillButton(
                title: String(localized: "onboarding.keys.continue"),
                style: .primary,
                disabled: source.powersLiveText == false,
                action: onContinue
            )
            .accessibilityIdentifier("onboarding.live-text.continue")
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: appeared)
        .onAppear {
            appeared = true
            if let fixture {
                // 画给测试看:摆哪一面由它说,不读真的 store。
                mode = fixture.onboardingMode ?? .inviteCode
                return
            }
            viewModel.refresh()
            mode = .initial(
                inviteActive: invite.isActive,
                hasOwnKey: viewModel.snapshot(for: .soniox).isActive
            )
        }
        .onDisappear {
            code = ""
        }
        // 再走一遍引导的人已经有邀请码:把还能录多久问回来,状态才报得出数。
        .task {
            guard fixture == nil else { return }
            await invite.refreshQuota()
        }
    }

    // MARK: 邀请码

    private var inviteEntry: some View {
        VStack(alignment: .leading, spacing: Spacing.xsm) {
            HStack(spacing: Spacing.sm) {
                OnboardingField(
                    placeholder: String(localized: "community_invite.placeholder"),
                    text: $code
                )
                .disabled(isWorking)
                .onSubmit(redeem)
                .settingsExplained(String(localized: "onboarding.live_text.subtitle"))
                .accessibilityLabel(String(localized: "settings.live_text.invite_field_label"))
                .accessibilityIdentifier("onboarding.live-text.invite-code")

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: OnboardingMetrics.controlHeight, height: OnboardingMetrics.controlHeight)
                } else {
                    // 能出字以前,这一步该按的是它;能出字以后,该按的是「继续」。
                    OnbPillButton(
                        title: String(localized: "onboarding.live_text.redeem"),
                        style: source.powersLiveText ? .ghost : .primary,
                        disabled: code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: redeem
                    )
                    .accessibilityIdentifier("onboarding.live-text.redeem")
                }
            }

            inviteStatus
        }
    }

    /// 栏下面那一行:出了错说错在哪;已经能出字了,一个图标加几个词 —— 靠的
    /// 是什么、还能录多久。
    @ViewBuilder
    private var inviteStatus: some View {
        if let error = errorMessage {
            SettingsProblem(error)
        } else if source != .nothing {
            SettingsStatus(
                source.status,
                systemImage: source.powersLiveText ? "checkmark.circle.fill" : source.symbol,
                tint: source.powersLiveText ? .signalGreen : .signalAmber,
                help: source.sentence
            )
            .accessibilityIdentifier("onboarding.live-text.status")
        }
    }

    // MARK: 两颗安静的胶囊

    /// 上下摆,不并排:窗口窄、字又长的语言里,并排摆不下。
    private var quietChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch mode {
            case .inviteCode:
                // 供应商的名字只在这一处和「设置 › 高级」出现:要用自己密钥的人
                // 得知道是哪家的密钥。名字从账户来,不在这里写死。
                ActionPill(
                    String(
                        format: String(localized: "onboarding.live_text.use_own_key_format"),
                        ProviderCredentialAccount.soniox.displayName
                    ),
                    systemImage: "key",
                    style: .quiet
                ) {
                    mode = .ownKey
                }
                .accessibilityIdentifier("onboarding.live-text.use-own-key")
            case .ownKey:
                ActionPill(
                    String(localized: "onboarding.live_text.use_invite"),
                    systemImage: "gift",
                    style: .quiet
                ) {
                    mode = .inviteCode
                }
                .accessibilityIdentifier("onboarding.live-text.use-invite")
            }

            if source.powersLiveText == false {
                // 「先跳过，只录音」那一句在提示里。
                ActionPill(
                    String(localized: "onboarding.skip"),
                    systemImage: "forward",
                    style: .quiet,
                    help: String(localized: "onboarding.live_text.skip"),
                    action: onSkip
                )
                .accessibilityIdentifier("onboarding.live-text.skip")
            }
        }
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

/// 第二步里选了「用自己的密钥」以后换上来的那一面:一栏、「验证并保存」,
/// 下面一颗去拿密钥的胶囊。密钥仍然只经 `ProviderConnectionsViewModel` 进
/// 凭据会话,验证通过才存。栏旁边的 ⓘ 里是两句告知:验证只检查密钥、不上传
/// 录音;密钥未加密保存在这台 Mac 上。
private struct OwnSonioxKeyEntry: View {
    @ObservedObject var viewModel: ProviderConnectionsViewModel
    /// Whether this is the thing to press at this step.
    let isPrimary: Bool
    @ObservedObject private var verificationStore = ProviderConnectionVerificationStore.shared
    @Environment(\.settingsFixture) private var fixture

    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var snapshot: ProviderCredentialSnapshot {
        fixture?.keys[.soniox]?.snapshot ?? viewModel.snapshot(for: .soniox)
    }

    private var isConfigured: Bool {
        snapshot.isSaved && snapshot.isActive
    }

    private var verificationState: ProviderConnectionVerificationState {
        fixture?.keys[.soniox]?.verification ?? verificationStore.state(for: .soniox)
    }

    /// 去哪拿密钥的三步,在那颗胶囊的提示里。
    private var guide: String {
        [
            "onboarding.keys.guide.create",
            "onboarding.keys.guide.copy",
            "onboarding.keys.guide.paste",
        ]
        .map { String(localized: String.LocalizationValue($0)) }
        .joined(separator: " → ")
    }

    private var disclosure: String {
        [
            String(localized: "onboarding.keys.soniox.help"),
            String(localized: "settings.credentials.trust_boundary_notice"),
        ].joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xsm) {
            if isConfigured {
                HStack(spacing: Spacing.sm) {
                    verificationBadge
                    ActionPill(
                        String(localized: "settings.credentials.verify"),
                        systemImage: "checkmark.shield"
                    ) {
                        viewModel.verifySavedCredential(for: .soniox)
                    }
                    .disabled(verificationState == .checking)
                }
                .frame(minHeight: OnboardingMetrics.controlHeight)
            } else {
                HStack(spacing: Spacing.sm) {
                    OnboardingField(
                        placeholder: String(localized: "onboarding.keys.paste"),
                        text: $draft,
                        isSecure: true
                    )
                    .disabled(isWorking)
                    .onSubmit(verifyAndSave)
                    .accessibilityIdentifier("onboarding.live-text.own-key")

                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: OnboardingMetrics.controlHeight, height: OnboardingMetrics.controlHeight)
                    } else {
                        // 两个词:旁边 ⓘ 里的告知说的就是这颗按钮的名字。验证通过
                        // 才存的那一句在提示里。
                        OnbPillButton(
                            title: String(localized: "onboarding.keys.verify_and_save"),
                            style: isPrimary ? .primary : .ghost,
                            disabled: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            help: String(
                                format: String(localized: "settings.credentials.verify_before_save_format"),
                                ProviderCredentialAccount.soniox.displayName
                            ),
                            action: verifyAndSave
                        )
                    }

                    InfoButton(disclosure)
                }

                verificationBadge

                ActionPill(
                    String(localized: "onboarding.keys.open_soniox"),
                    systemImage: "arrow.up.right",
                    style: .quiet,
                    help: guide
                ) {
                    NSWorkspace.shared.open(Self.consoleURL)
                }
            }

            if let errorMessage {
                SettingsProblem(errorMessage, tint: .signalRed)
            }
        }
        .onAppear {
            guard fixture == nil, isConfigured else { return }
            verificationStore.verifyIfNeeded(
                account: .soniox,
                isConfigured: true
            )
        }
        .onDisappear {
            draft = ""
            errorMessage = nil
        }
    }

    private static let consoleURL = URL(string: "https://console.soniox.com")!

    @ViewBuilder
    private var verificationBadge: some View {
        switch verificationState {
        case .checking:
            SettingsStatus(
                String(localized: "settings.credentials.verifying"),
                systemImage: "arrow.triangle.2.circlepath",
                tint: .signalBlue
            )
        case .ready:
            SettingsStatus(
                String(localized: "settings.credentials.status.verified"),
                systemImage: "checkmark.shield.fill",
                tint: .signalGreen
            )
        case .unverified:
            if isConfigured {
                SettingsStatus(
                    String(localized: "settings.credentials.status.saved"),
                    systemImage: "key.fill",
                    tint: .signalBlue
                )
            }
        default:
            SettingsProblem(
                ProviderConnectionVerificationFailure(verificationState, account: .soniox)
                    .localizedDescription
            )
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
            } catch is ProviderConnectionVerificationFailure {
                // The line under the field already shows this verdict.
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 第三步:麦克风

/// 「允许」。允许了是一个勾和一个词;拒绝过的人,系统不会再问第二次,所以是
/// 那一句(去系统设置里打开,再回来)和「打开系统设置」。不允许也能进去:
/// 第一次录音的时候还会再问 —— 那一句在「进入 ZuTalk」的提示里。
struct PermissionsScreen: View {
    @ObservedObject var controller: OnboardingController
    var onContinue: () -> Void
    var onBack: () -> Void

    @State private var pollTimer: Timer?
    @State private var appeared = false

    private var status: PermissionStatus {
        controller.permissionStatuses[.microphone] ?? .notDetermined
    }

    var body: some View {
        OnboardingStep(title: String(localized: "onboarding.step.microphone")) {
            switch status {
            case .granted:
                SettingsStatus(
                    String(localized: "onboarding.permissions.allowed"),
                    systemImage: "checkmark.circle.fill",
                    tint: .signalGreen,
                    font: OnboardingMetrics.fieldFont
                )
                .frame(minHeight: OnboardingMetrics.controlHeight)
                .transition(.opacity)
                .accessibilityIdentifier("onboarding.permissions.granted")
            case .notDetermined:
                OnbPillButton(
                    title: String(localized: "onboarding.permissions.allow"),
                    icon: "mic.fill",
                    style: .primary,
                    help: [
                        String(localized: "onboarding.permissions.subtitle"),
                        String(localized: "onboarding.permissions.mic.usage"),
                    ].joined(separator: "\n")
                ) {
                    controller.resolvePermission(.microphone)
                }
                .accessibilityIdentifier("onboarding.permissions.action")
            case .denied:
                // 拒绝过的人按了按钮会被带到系统设置:说清楚去那里做什么、
                // 做完回哪。
                SettingsProblem(
                    String(localized: "onboarding.permissions.denied_hint"),
                    font: OnboardingMetrics.fieldFont
                )
                .accessibilityIdentifier("onboarding.permissions.denied")
                OnbPillButton(
                    title: String(localized: "onboarding.permissions.action.open_system_settings"),
                    icon: "gearshape",
                    style: .primary
                ) {
                    controller.resolvePermission(.microphone)
                }
                .accessibilityIdentifier("onboarding.permissions.action")
            }
        } footer: {
            OnbPillButton(
                title: String(localized: "onboarding.back"),
                icon: "arrow.left",
                style: .ghost,
                action: onBack
            )

            Spacer()

            // 麦克风允许了,这一步该按的就是它;还没允许,它是描边的那一个。
            OnbPillButton(
                title: String(localized: "onboarding.finish"),
                style: controller.allPermissionsGranted ? .primary : .ghost,
                help: controller.allPermissionsGranted
                    ? nil
                    : String(localized: "onboarding.permissions.hint"),
                action: onContinue
            )
            .modifier(ReadyPulseModifier(active: controller.allPermissionsGranted))
            .accessibilityIdentifier("onboarding.permissions.finish")
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: appeared)
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
