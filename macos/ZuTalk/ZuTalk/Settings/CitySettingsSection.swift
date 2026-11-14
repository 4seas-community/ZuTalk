// CitySettingsSection.swift
// 城在设置里的两块,都在「账号」一节:
//   - `CityIdentitySection`:最上面。没登录是登录卡,登录了是「这是谁」和退出登录。
//     ZuTalk 的登录就是这个身份(Zu 的身份,现在也就是城的扫码登录);身份体系
//     还在定,这里只把现成的登录放到账号该在的位置,怎么登录没有动。
//   - `CityArchiveSection`:最下面,登录以后才有。交什么、录完以后什么时候交、
//     已经交出去的。
//
// 一行就是一个名字加一个控件(docs/product/interface-layers.md「界面怎么写」)。
// 原来写在行下面的说明成了控件的悬停提示;必须让人读到的告知在 ⓘ 和确认框里:
//   - 登录交过来的是这个人在城里的整把钥匙(城没有「只能交素材」的小钥匙),
//     交到活动的录音默认带音频,交上去的是公开的、删不掉 —— 登录卡上的 ⓘ、
//     登录以后名字旁边的 ⓘ;
//   - 「音频」开关旁边的 ⓘ:连音频一起交,公开,删不掉,城的主办能拿它再转写;
//   - 退出登录的确认框:一句话,删掉的是什么、留下的是什么。

import SwiftUI

struct CityIdentitySection: View {
    @ObservedObject private var city = CityStore.shared
    @State private var confirmingSignOut = false

    var body: some View {
        Group {
            if let account = city.account {
                SettingsGroup(title: String(localized: "city.identity.word")) {
                    CityAccountCard(account: account) { confirmingSignOut = true }
                }
            } else {
                SettingsGroup(title: String(localized: "city.identity.word")) {
                    CitySignInCard()
                }
            }
        }
        // 走开就不等了:码只有五分钟,留一个没人看的码在后台等没有意义。
        .onDisappear { city.cancelLogin() }
        .alert(
            String(localized: "city.signout.confirm_title"),
            isPresented: $confirmingSignOut
        ) {
            Button(String(localized: "city.signout.button"), role: .destructive) {
                city.signOut()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "city.signout.confirm_one"))
        }
    }
}

/// 登录以后的那一行:是谁、哪座城、退出登录。
struct CityAccountCard: View {
    let account: FfiCityAccount
    let onSignOut: () -> Void

    var body: some View {
        SettingsCard {
            SettingsFullRow {
                HStack(spacing: Spacing.xsm) {
                    Text(CityText.initial(account.personName))
                        .font(Font.sans13Semibold)
                        .foregroundColor(.brandAccentForeground)
                        .frame(width: 30, height: 30)
                        .background(Color.brandAccent)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.personName.isEmpty
                            ? String(localized: "city.settings.unnamed")
                            : account.personName)
                            .font(Font.sans12)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        Text(CityText.role(account) + " · " + account.server)
                            .font(Font.sans11)
                            .foregroundColor(.textTertiary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.citySettingsAccount)
                    // 这台 Mac 拿着什么、能做什么、存在哪。
                    InfoButton(
                        [CityText.signInDisclosure, String(localized: "city.settings.stored_detail")]
                            .joined(separator: "\n"),
                        accessibilityLabel: String(localized: "city.identity.word")
                    )
                    Spacer(minLength: Spacing.md)
                    ActionPill(
                        String(localized: "city.signout.button"),
                        systemImage: "rectangle.portrait.and.arrow.right",
                        action: onSignOut
                    )
                    .accessibilityIdentifier(AccessibilityID.citySettingsSignOut)
                }
            }
        }
    }
}

/// 「城的档案馆」:交什么、录完以后什么时候交、已经交出去的每一场。
/// 没登录就什么都没有 —— 没登录的人在设置里看不到「档案馆」三个字。
struct CityArchiveSection: View {
    @ObservedObject private var city = CityStore.shared

    var body: some View {
        if city.account != nil {
            SettingsGroup(title: String(localized: "city.share.title")) {
                CityArchiveOptionsCard(options: city.options) { city.setOptions($0) }
                CityFilingsCard()
            }
        }
    }
}

/// 交什么、什么时候交:四行,每行一个名字加一个控件。
///   - 文字:总是交,一个锁住的值;
///   - 说话人:开关;
///   - 音频:开关,默认开。旁边的 ⓘ 写着交上去是公开的、删不掉;
///   - 时机:一颗写着当前值的胶囊,自动 / 先问。
/// 标记不交(0.8.3 起),所以没有那一行。
struct CityArchiveOptionsCard: View {
    let options: FfiCityFilingOptions
    let onChange: (FfiCityFilingOptions) -> Void

    var body: some View {
        SettingsCard {
            SettingsRow(String(localized: "city.what.text_word")) {
                // 锁住的值:和开关一样高,点不动。
                Label(String(localized: "city.what.always"), systemImage: "lock.fill")
                    .font(PillMetrics.font)
                    .foregroundColor(.textTertiary)
                    .frame(height: PillMetrics.height)
                    .help(String(localized: "city.what.text_detail"))
                    .accessibilityHint(Text(String(localized: "city.what.text_detail")))
            }
            SettingsRowDivider()
            SettingsRow(String(localized: "city.what.speakers_word")) {
                CitySwitch(
                    isOn: options.speakerNames,
                    label: String(localized: "city.what.speakers_word"),
                    help: String(localized: "city.what.speakers_detail")
                ) { on in
                    var next = options
                    next.speakerNames = on
                    onChange(next)
                }
                .accessibilityIdentifier(AccessibilityID.citySettingsSpeakerNames)
            }
            SettingsRowDivider()
            SettingsRow(String(localized: "city.what.audio")) {
                HStack(spacing: Spacing.xs) {
                    InfoButton(
                        CityText.audioDisclosure,
                        accessibilityLabel: String(localized: "city.what.audio")
                    )
                    CitySwitch(
                        isOn: options.audio,
                        label: String(localized: "city.what.audio"),
                        help: CityText.audioDisclosure
                    ) { on in
                        var next = options
                        next.audio = on
                        onChange(next)
                    }
                    .accessibilityIdentifier("settings.city.audio")
                }
            }
            SettingsRowDivider()
            SettingsRow(String(localized: "city.when.word")) {
                MenuPill(
                    String(localized: options.automatic ? "city.when.auto_word" : "city.when.ask_word"),
                    systemImage: options.automatic ? "arrow.up.circle" : "hand.raised",
                    help: String(localized: options.automatic
                        ? "city.when.automatic_detail"
                        : "city.when.ask_detail"),
                    accessibilityLabel: String(localized: "city.when.word")
                ) {
                    [
                        PillMenuItem(String(localized: "city.when.auto_word"), isOn: options.automatic) {
                            set(automatic: true)
                        },
                        PillMenuItem(String(localized: "city.when.ask_word"), isOn: options.automatic == false) {
                            set(automatic: false)
                        },
                    ]
                }
                .accessibilityIdentifier(AccessibilityID.citySettingsWhen)
            }
        }
    }

    private func set(automatic: Bool) {
        var next = options
        next.automatic = automatic
        onChange(next)
    }
}

// MARK: - 这一页上小控件的样子

/// 开关:一颗写着「开」「关」的胶囊,和「账号」页上别的开关一个样子、一样高。
struct CitySwitch: View {
    let isOn: Bool
    /// 这个开关管的是什么,给旁白。
    let label: String
    /// 原来写在行下面的那一句。
    var help: String?
    let action: (Bool) -> Void

    var body: some View {
        TogglePill(
            isOn: isOn,
            on: .init(String(localized: "city.switch.on"), systemImage: "checkmark.circle.fill"),
            off: .init(String(localized: "city.switch.off"), systemImage: "circle"),
            help: help,
            accessibilityLabel: label
        ) {
            action(isOn == false)
        }
    }
}

/// 一栏输入:和胶囊一样高,方角 —— 圆的是点的,方的是填的。
struct CityFieldChrome: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(PillMetrics.font)
            .foregroundColor(.textPrimary)
            .padding(.horizontal, PillMetrics.horizontalPadding)
            .frame(height: PillMetrics.height)
            .background(Color.bgRoot)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.borderActive, lineWidth: Stroke.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
