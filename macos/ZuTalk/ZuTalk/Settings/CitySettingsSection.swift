// CitySettingsSection.swift
// 设置 › 城:登录你在城里的身份,之后录完的文字稿可以以你的名义交到那座城的
// 档案馆。登录、交什么、录完以后什么时候交、已经交出去的,都在这一节。
//
// 没登录时,这是 App 里唯一出现「城」的地方。
//
// 登录交过来的是这个人在城里的整把钥匙(城没有「只能交素材」的小钥匙),
// 所以登录和退出两处都照实写:这台 Mac 能以你的名义做什么、退出删掉的是什么。

import SwiftUI

struct CitySettingsSection: View {
    @ObservedObject private var city = CityStore.shared
    @State private var confirmingSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SettingsPageHeader(
                title: String(localized: "settings.section.city_name"),
                subtitle: String(localized: "city.settings.subtitle")
            )

            if let account = city.account {
                accountCard(account)
                whatCard
                whenCard
                CityFilingsCard()
            } else {
                CitySignInCard()
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
