// CitySignInCard.swift
// 设置 › 城 里的登录卡片。城里没有账号密码,一个人就是一把钥匙;登录用的是
// 城现成的「连接新设备」:这台 Mac 出一个码,已经登录的那台设备扫它(或粘贴它),
// 两边核对同一个六位数,人在那台设备上确认。没有别的设备在手边时填恢复密钥。
//
// 卡片上照实写两件事:登录以后这台 Mac 能以你的名义做什么,以及音频不外传。

import SwiftUI

struct CitySignInCard: View {
    @ObservedObject private var city = CityStore.shared
    @State private var server = CityStore.defaultServer
    @State private var showsRecoveryKey = false
    /// 只在这一栏里待到按下登录;交给核心以后立刻清掉。
    @State private var recoveryKey = ""

    private static let qrSide: CGFloat = 136

    var body: some View {
        SettingsCard(title: title, subtitle: subtitle) {
            switch city.login {
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
                SettingsRow(
                    String(localized: "city.signin.lapsed_title"),
                    description: String(localized: "city.signin.lapsed_detail")
                ) {
                    Button(String(localized: "city.signin.new_code")) {
                        city.beginLogin(server: lapsedServer)
                    }
                    .accessibilityIdentifier(AccessibilityID.citySettingsNewCode)
                }
                SettingsRowDivider()
                alternativesRow
            case .recovering:
                progressRow(String(localized: "city.signin.signing_in"))
            }

            if let problem = city.loginProblem {
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
                    .accessibilityIdentifier(AccessibilityID.citySettingsProblem)
                }
            }

            SettingsRowDivider()
            SettingsFullRow {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label(String(localized: "city.signin.trust"), systemImage: "person.badge.key")
                    Label(String(localized: "share.audio_never"), systemImage: "waveform.slash")
                }
                .font(Font.sans11)
                .foregroundColor(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(AccessibilityID.citySettingsSignIn)
    }

    private var title: String {
        // 城的名字是服务器说的,码回来之前还不知道。
        if case .offered(let offer, _) = city.login, offer.cityName.isEmpty == false {
            return String(format: String(localized: "city.signin.title_format"), offer.cityName)
        }
        return String(localized: "city.signin.title")
    }

    private var subtitle: String {
        city.loginServer ?? String(localized: "city.signin.address_hint")
    }

    // MARK: - 填网址

    private var addressRow: some View {
        SettingsFullRow {
            HStack(spacing: Spacing.sm) {
                TextField(String(localized: "city.signin.address_placeholder"), text: $server)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onSubmit(begin)
                    .accessibilityLabel(Text(String(localized: "city.signin.address_label")))
                    .accessibilityIdentifier(AccessibilityID.citySettingsServer)
                Button(String(localized: "city.signin.continue"), action: begin)
                    .buttonStyle(.borderedProminent)
                    .disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(AccessibilityID.citySettingsContinue)
            }
        }
    }

    private func begin() {
        showsRecoveryKey = false
        city.beginLogin(server: server)
    }

    private func progressRow(_ text: String) -> some View {
        SettingsFullRow {
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(Font.sans12)
                    .foregroundColor(.textSecondary)
            }
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
                    step(1, String(localized: "city.signin.step_scan"))
                    step(2, String(localized: "city.signin.step_check"))
                    HStack(spacing: Spacing.sm) {
                        // 码也可以拷贝过去粘贴:旧设备是同一台电脑上的浏览器时,没法扫。
                        Button {
                            city.copyLoginCode(offer)
                        } label: {
                            Label(String(localized: "city.signin.copy_code"), systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier(AccessibilityID.citySettingsCopyCode)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(String(
                                format: String(localized: "city.signin.expires_format"),
                                DevicesSettingsSection.countdown(
                                    until: Date(timeIntervalSince1970: TimeInterval(offer.expiresAtEpoch)),
                                    now: context.date
                                )
                            ))
                            .font(Font.sans11)
                            .foregroundColor(.textTertiary)
                        }
                    }
                    if let digits, digits.isEmpty == false {
                        checkDigits(digits)
                    }
                }
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
            city.loginOfferLapsed(offer)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(String(number))
                .font(Font.mono10Medium)
                .foregroundColor(.brandAccent)
                .frame(width: 18, height: 18)
                .background(Color.brandAccentSoft)
                .clipShape(Circle())
            Text(text)
                .font(Font.sans12)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// 两边显示同一个六位数。数字大、等宽:人要隔着两块屏幕逐位对。
    private func checkDigits(_ digits: String) -> some View {
        HStack(spacing: Spacing.xsm) {
            Text(String(localized: "city.signin.check_label"))
                .font(Font.sans11)
                .foregroundColor(.textTertiary)
            Text(digits)
                .font(Font.titleLG.monospacedDigit())
                .foregroundColor(.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: Spacing.sm)
            ProgressView().controlSize(.small)
            Text(String(localized: "city.signin.check_waiting"))
                .font(Font.sans11)
                .foregroundColor(.textTertiary)
        }
        .padding(.horizontal, Spacing.xsm)
        .padding(.vertical, Spacing.sm)
        .surfaceCard(
            fill: Color.bgRoot,
            cornerRadius: Radius.sm,
            border: Color.borderSubtle,
            borderWidth: Stroke.thin
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.citySettingsCheckDigits)
    }

    // MARK: - 恢复密钥、换一座城

    private var alternativesRow: some View {
        SettingsFullRow {
            HStack(spacing: Spacing.sm) {
                Text(String(localized: "city.signin.no_device"))
                    .font(Font.sans11)
                    .foregroundColor(.textTertiary)
                Spacer(minLength: Spacing.sm)
                Button(String(localized: "city.signin.use_recovery_key")) {
                    showsRecoveryKey.toggle()
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(AccessibilityID.citySettingsUseRecoveryKey)
                Button(String(localized: "city.signin.change_city")) {
                    showsRecoveryKey = false
                    recoveryKey = ""
                    city.cancelLogin()
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(AccessibilityID.citySettingsChangeCity)
            }
            .font(Font.sans11)

            if showsRecoveryKey {
                HStack(spacing: Spacing.sm) {
                    SecureField(String(localized: "city.signin.recovery_placeholder"), text: $recoveryKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signInWithRecoveryKey)
                        .accessibilityLabel(Text(String(localized: "city.signin.recovery_placeholder")))
                        .accessibilityIdentifier(AccessibilityID.citySettingsRecoveryKey)
                    Button(String(localized: "city.signin.sign_in"), action: signInWithRecoveryKey)
                        .disabled(recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier(AccessibilityID.citySettingsRecoverySignIn)
                }
                Text(String(localized: "city.signin.recovery_hint"))
                    .font(Font.sans11)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signInWithRecoveryKey() {
        let key = recoveryKey
        recoveryKey = ""
        city.loginWithRecoveryKey(key)
    }
}
