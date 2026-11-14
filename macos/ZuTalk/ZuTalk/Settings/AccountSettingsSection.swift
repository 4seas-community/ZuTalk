// AccountSettingsSection.swift
// 设置 › 账号:和「我是谁」有关的四件事,从上到下,每一件一个词的小标题:
//   1. 身份 —— 没登录是登录,登录了是这是谁、退出登录(城那一块自己画);
//   2. 出字 —— 现在靠什么出字(邀请码、自己的密钥、还没有),邀请码在这里填;
//   3. 设备 —— 自己的几台 Mac 之间同步;
//   4. 档案馆 —— 登录以后才有:交什么、交出去的录音(城那一块自己画)。
//
// 0.8.1 这四件事分在「城」「实时字幕」「设备」三节,人要先知道「邀请码算字幕
// 的事」「登录算城的事」才找得到。现在都在人会先点开的这一节。
//
// 这一页没有介绍自己的那句话:四个小标题就是它有什么。
// 这一页自己不盯任何 store:每一块自己盯自己要的,一块变了不会把整页重画。

import SwiftUI

struct AccountSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SettingsPageHeader(title: String(localized: "settings.section.account_name"))

            CityIdentitySection()

            SettingsGroup(title: String(localized: "onboarding.step.live_text")) {
                CommunityInviteSettingsCard()
            }

            DevicesSettingsSection()

            CityArchiveSection()
        }
    }
}
