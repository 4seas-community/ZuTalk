// CitySignInCard.swift
// 「设置 › 账号」最上面的登录卡片。城里没有账号密码,一个人就是一把钥匙;登录
// 用的是城现成的「连接新设备」:这台 Mac 出一个码,已经登录的那台设备扫它
// (或粘贴它),两边核对同一个六位数,人在那台设备上确认。没有别的设备在手边时
// 填恢复密钥。
//
// 卡片上只有控件和状态:网址栏和「继续」;然后是码、「复制登录码」、倒计时、
// 六位核对数,底下一排安静的「恢复密钥」「换一座城」。
//
// 必须让人读到的在 ⓘ 里(`CityText.signInDisclosure`),每一步都点得到:登录
// 以后这台 Mac 能以你的名义做事;交到活动的录音默认带音频;交上去的是公开的,
// 删不掉。怎么扫码的那两步在码旁边的 ⓘ 里。

import SwiftUI

struct CitySignInCard: View {
    @ObservedObject private var city = CityStore.shared
    @State private var server = CityStore.defaultServer
    @State private var showsRecoveryKey = false
    /// 只在这一栏里待到按下登录;交给核心以后立刻清掉。
    @State private var recoveryKey = ""

    var body: some View {
        CitySignInCardContent(
            login: city.login,
            problem: city.loginProblem,
            server: $server,
            showsRecoveryKey: $showsRecoveryKey,
            recoveryKey: $recoveryKey,
            onBegin: {
                showsRecoveryKey = false
                city.beginLogin(server: server)
            },
            onNewCode: { city.beginLogin(server: $0) },
            onCopy: { city.copyLoginCode($0) },
            onLapsed: { city.loginOfferLapsed($0) },
            onChangeCity: {
                showsRecoveryKey = false
                recoveryKey = ""
                city.cancelLogin()
            },
            onRecover: {
                let key = recoveryKey
                recoveryKey = ""
                city.loginWithRecoveryKey(key)
            }
        )
    }
}

/// 卡片本身:给什么画什么,所以每一步都能单独拿出来看。
struct CitySignInCardContent: View {
    let login: CityStore.Login
    let problem: String?
    @Binding var server: String
    @Binding var showsRecoveryKey: Bool
    @Binding var recoveryKey: String
    let onBegin: () -> Void
    let onNewCode: (String) -> Void
    let onCopy: (FfiCityLoginOffer) -> Void
    let onLapsed: (FfiCityLoginOffer) -> Void
    let onChangeCity: () -> Void
    let onRecover: () -> Void

    private static let qrSide: CGFloat = 136

    var body: some View {
        SettingsCard(title: title) {
            switch login {
            case .signedOut:
                addressRow
            case .requesting:
                progressRow(String(localized: "city.signin.requesting"))
                // 网络慢的时候这一步会等一会儿:留着退路,不把人困在转圈里。
                SettingsRowDivider()
                alternativesRow
            case .offered(let offer, let digits):
                offerRow(offer, digits: digits)
                SettingsRowDivider()
                alternativesRow
            case .lapsed(let lapsedServer):
                SettingsFullRow {
                    HStack(spacing: Spacing.sm) {
                        // 出了什么事,和唯一的动作。
                        Label(String(localized: "city.signin.lapsed_title"), systemImage: "clock.badge.exclamationmark")
                            .font(PillMetrics.font)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                            .help(String(localized: "city.signin.lapsed_detail"))
                        Spacer(minLength: Spacing.sm)
                        ActionPill(
                            String(localized: "city.signin.new_code"),
                            systemImage: "arrow.clockwise",
                            help: String(localized: "city.signin.lapsed_detail")
                        ) {
                            onNewCode(lapsedServer)
                        }
                        .accessibilityIdentifier(AccessibilityID.citySettingsNewCode)
                    }
                }
                SettingsRowDivider()
                alternativesRow
            case .recovering:
                progressRow(String(localized: "city.signin.signing_in"))
            }

            if let problem {
                SettingsRowDivider()
                SettingsFullRow {
                    Label {
                        Text(problem)
                            .foregroundColor(.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.error)
                    }
                    .font(Font.sans12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityID.citySettingsProblem)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.citySettingsSignIn)
    }

    /// 码要来了才有小标题:这时候要让人看见登录的是哪座城、哪个网址。
    private var title: String? {
        switch login {
        case .signedOut:
            return nil
        case .offered(let offer, _):
            // 城的名字是服务器说的,码回来之前还不知道。
            return offer.cityName.isEmpty ? offer.server : offer.cityName + " · " + offer.server
        case .requesting(let server), .lapsed(let server), .recovering(let server):
            return server
        }
    }

    /// 登录意味着什么:每一步都点得到。
    private var disclosure: some View {
        InfoButton(
            [String(localized: "settings.account.signin_detail"), CityText.signInDisclosure]
                .joined(separator: "\n"),
            accessibilityLabel: String(localized: "city.signin.title")
        )
    }

    // MARK: - 填网址

    private var addressRow: some View {
        SettingsFullRow {
            HStack(spacing: Spacing.sm) {
                TextField(String(localized: "city.signin.address_placeholder"), text: $server)
                    .disableAutocorrection(true)
                    .onSubmit(onBegin)
                    .modifier(CityFieldChrome())
                    .accessibilityLabel(Text(String(localized: "city.signin.address_label")))
                    .accessibilityIdentifier(AccessibilityID.citySettingsServer)
                disclosure
                ActionPill(
                    String(localized: "city.signin.continue"),
                    systemImage: "arrow.right.circle",
                    action: onBegin
                )
                .disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier(AccessibilityID.citySettingsContinue)
            }
        }
    }

    private func progressRow(_ text: String) -> some View {
        SettingsFullRow {
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(PillMetrics.font)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
            .frame(height: PillMetrics.height)
        }
    }

    // MARK: - 扫码

    private func offerRow(_ offer: FfiCityLoginOffer, digits: String?) -> some View {
        SettingsFullRow {
            HStack(alignment: .top, spacing: Spacing.lg) {
                if let qr = ShareQRCode.image(for: offer.code) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: Self.qrSide, height: Self.qrSide)
                        .padding(ShareQRCode.quietZone(for: Self.qrSide))
                        // 码必须是白底黑点,深色界面里也一样,相机才认得出。
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .accessibilityLabel(Text(String(localized: "city.signin.qr_label")))
                        .accessibilityIdentifier(AccessibilityID.citySettingsQRCode)
                }
                VStack(alignment: .leading, spacing: Spacing.xsm) {
                    HStack(spacing: Spacing.sm) {
                        // 码也可以拷贝过去粘贴:旧设备是同一台电脑上的浏览器时,没法扫。
                        ActionPill(
                            String(localized: "city.signin.copy_code"),
                            systemImage: "doc.on.doc"
                        ) {
                            onCopy(offer)
                        }
                        .accessibilityIdentifier(AccessibilityID.citySettingsCopyCode)
                        // 怎么扫、怎么核对:两步,点开看。
                        InfoButton(
                            [String(localized: "city.signin.step_scan"), String(localized: "city.signin.step_check")]
                                .joined(separator: "\n"),
                            accessibilityLabel: String(localized: "city.signin.qr_label")
                        )
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(
                            String(
                                format: String(localized: "city.signin.expires_format"),
                                DevicesSettingsSection.countdown(
                                    until: Date(timeIntervalSince1970: TimeInterval(offer.expiresAtEpoch)),
                                    now: context.date
                                )
                            ),
                            systemImage: "clock"
                        )
                        .font(Font.sans11)
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                    }
                    if let digits, digits.isEmpty == false {
                        checkDigits(digits)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        // 到点就收掉:过期的码留在屏幕上,人会对着一个扫不了的码等。
        .task(id: offer.code) {
            let remaining = TimeInterval(offer.expiresAtEpoch) - Date().timeIntervalSince1970
            do {
                try await MontereyTaskSleep.seconds(remaining)
            } catch {
                return
            }
            onLapsed(offer)
        }
    }

    /// 两边显示同一个六位数。数字大、等宽:人要隔着两块屏幕逐位对。
    private func checkDigits(_ digits: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "city.signin.check_label"))
                .font(Font.sans11)
                .foregroundColor(.textTertiary)
            Text(digits)
                .font(Font.titleLG.monospacedDigit())
                .foregroundColor(.textPrimary)
                .textSelection(.enabled)
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(String(localized: "city.signin.check_waiting"))
                    .font(Font.sans11)
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.citySettingsCheckDigits)
    }

    // MARK: - 恢复密钥、换一座城

    private var alternativesRow: some View {
        SettingsFullRow {
            HStack(spacing: Spacing.md) {
                ActionPill(
                    String(localized: "city.signin.recovery_placeholder"),
                    systemImage: "key",
                    style: .quiet,
                    help: [String(localized: "city.signin.no_device"), String(localized: "city.signin.use_recovery_key")]
                        .joined(separator: " ")
                ) {
                    showsRecoveryKey.toggle()
                }
                .accessibilityIdentifier(AccessibilityID.citySettingsUseRecoveryKey)
                ActionPill(
                    String(localized: "city.signin.change_city"),
                    systemImage: "arrow.uturn.backward",
                    style: .quiet,
                    action: onChangeCity
                )
                .accessibilityIdentifier(AccessibilityID.citySettingsChangeCity)
                Spacer(minLength: 0)
                disclosure
            }

            if showsRecoveryKey {
                HStack(spacing: Spacing.sm) {
                    SecureField(String(localized: "city.signin.recovery_placeholder"), text: $recoveryKey)
                        .onSubmit(onRecover)
                        .modifier(CityFieldChrome())
                        .accessibilityLabel(Text(String(localized: "city.signin.recovery_placeholder")))
                        .accessibilityIdentifier(AccessibilityID.citySettingsRecoveryKey)
                    // 恢复密钥就是身份本身:填之前读得到。
                    InfoButton(
                        String(localized: "city.signin.recovery_hint"),
                        accessibilityLabel: String(localized: "city.signin.recovery_placeholder")
                    )
                    ActionPill(
                        String(localized: "city.signin.sign_in"),
                        systemImage: "arrow.right.circle",
                        action: onRecover
                    )
                    .disabled(recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(AccessibilityID.citySettingsRecoverySignIn)
                }
            }
        }
    }
}
