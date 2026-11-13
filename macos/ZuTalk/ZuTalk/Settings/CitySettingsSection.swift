// CitySettingsSection.swift
// 城在设置里的两块,都在「账号」一节:
//   - `CityIdentitySection`:最上面。没登录是登录卡,登录了是「这是谁」和退出登录。
//     ZuTalk 的登录就是这个身份(Zu 的身份,现在也就是城的扫码登录);身份体系
//     还在定,这里只把现成的登录放到账号该在的位置,怎么登录没有动。
//   - `CityArchiveSection`:最下面,登录以后才有。交什么、录完以后什么时候交、
//     已经交出去的。
//
// 登录交过来的是这个人在城里的整把钥匙(城没有「只能交素材」的小钥匙),
// 所以登录和退出两处都照实写:这台 Mac 能以你的名义做什么、退出删掉的是什么。
// 登录卡上那一句只说登录今天能做的事,不替还没定的东西许诺。

import SwiftUI

struct CityIdentitySection: View {
    @ObservedObject private var city = CityStore.shared
    @State private var confirmingSignOut = false

    var body: some View {
        Group {
            if let account = city.account {
                SettingsGroup(title: String(localized: "settings.account.identity_title")) {
                    accountCard(account)
                }
            } else {
                SettingsGroup(
                    title: String(localized: "settings.account.signin_title"),
                    subtitle: String(localized: "settings.account.signin_detail")
                ) {
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
            Text(String(localized: "city.signout.confirm_message"))
        }
    }

    // MARK: - 已登录

    private func accountCard(_ account: FfiCityAccount) -> some View {
        SettingsCard(title: String(localized: "city.settings.signed_in")) {
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
                        Text(CityText.role(account) + " · " + account.server)
                            .font(Font.sans11)
                            .foregroundColor(.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.citySettingsAccount)
                    Spacer(minLength: Spacing.md)
                    Button(String(localized: "city.signout.action")) {
                        confirmingSignOut = true
                    }
                    .accessibilityIdentifier(AccessibilityID.citySettingsSignOut)
                }
            }
            SettingsRowDivider()
            SettingsRow(
                String(localized: "city.settings.stored_title"),
                description: String(localized: "city.settings.stored_detail")
            ) {
                EmptyView()
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
            SettingsGroup(
                title: String(localized: "city.archive.title"),
                subtitle: String(localized: "city.archive.subtitle")
            ) {
                whatCard
                whenCard
                CityFilingsCard()
            }
        }
    }

    /// 交什么。两行开关,两行锁住的说明:原文和译文总是交,音频从不交 ——
    /// 后一行是说明,不是开关。
    private var whatCard: some View {
        SettingsCard(
            title: String(localized: "city.what.title"),
            subtitle: String(localized: "city.what.subtitle")
        ) {
            SettingsRow(
                String(localized: "city.what.text"),
                description: String(localized: "city.what.text_detail")
            ) {
                Text(String(localized: "city.what.always"))
                    .font(Font.sans11)
                    .foregroundColor(.textTertiary)
            }
            SettingsRowDivider()
            SettingsRow(
                String(localized: "city.what.speakers"),
                description: String(localized: "city.what.speakers_detail")
            ) {
                Toggle(String(localized: "city.what.speakers"), isOn: Binding(
                    get: { city.options.speakerNames },
                    set: { on in
                        var next = city.options
                        next.speakerNames = on
                        city.setOptions(next)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier(AccessibilityID.citySettingsSpeakerNames)
            }
            SettingsRowDivider()
            SettingsRow(
                String(localized: "city.what.marks"),
                description: String(localized: "city.what.marks_detail")
            ) {
                Toggle(String(localized: "city.what.marks"), isOn: Binding(
                    get: { city.options.marks },
                    set: { on in
                        var next = city.options
                        next.marks = on
                        city.setOptions(next)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier(AccessibilityID.citySettingsMarks)
            }
            SettingsRowDivider()
            SettingsRow(
                String(localized: "city.what.audio"),
                description: String(localized: "share.audio_never")
            ) {
                Label(String(localized: "city.what.never"), systemImage: "lock.fill")
                    .font(Font.sans11)
                    .foregroundColor(.textTertiary)
            }
        }
    }

    private var whenCard: some View {
        SettingsCard(title: String(localized: "city.when.title")) {
            SettingsRow(
                String(localized: "city.when.row"),
                description: String(localized: city.options.automatic
                    ? "city.when.automatic_detail"
                    : "city.when.ask_detail")
            ) {
                Picker(String(localized: "city.when.row"), selection: Binding(
                    get: { city.options.automatic },
                    set: { automatic in
                        var next = city.options
                        next.automatic = automatic
                        city.setOptions(next)
                    }
                )) {
                    Text(String(localized: "city.when.automatic")).tag(true)
                    Text(String(localized: "city.when.ask")).tag(false)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier(AccessibilityID.citySettingsWhen)
            }
        }
    }
}
