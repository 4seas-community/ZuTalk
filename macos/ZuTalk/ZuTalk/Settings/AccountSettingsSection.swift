// AccountSettingsSection.swift
// 设置 › 账号:和「我是谁」有关的四件事,从上到下:
//   1. 身份 —— 没登录是「用你的 Zu 身份登录」,登录了是这是谁、退出登录;
//   2. 转录和翻译 —— 现在靠什么出字(邀请码、自己的密钥、还没有),邀请码在这里填;
//   3. 我的设备 —— 自己的几台 Mac 之间同步;
//   4. 城的档案馆 —— 登录以后才有:交什么、交出去的录音。
//
// 0.8.1 这四件事分在「城」「实时字幕」「设备」三节,人要先知道「邀请码算字幕
// 的事」「登录算城的事」才找得到。现在都在人会先点开的这一节。
//
// 这一页自己不盯任何 store:每一块自己盯自己要的,一块变了不会把整页重画。

import SwiftUI

struct AccountSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SettingsPageHeader(
                    title: String(localized: "settings.section.account_name"),
                    subtitle: String(localized: "settings.account.subtitle")
                )
                CityIdentitySection()
            }

            SettingsGroup(title: String(localized: "settings.live_text.title")) {
                CommunityInviteSettingsCard()
            }

            DevicesSettingsSection()

            CityArchiveSection()
        }
    }
}
