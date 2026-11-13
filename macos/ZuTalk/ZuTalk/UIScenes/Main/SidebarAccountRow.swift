// SidebarAccountRow.swift
// 侧栏底部的一行:登录了是一个圆的首字和这个人的名字,没登录是一句安静的
// 「登录」。点它都到「设置 › 账号」。
//
// 账号得在主窗口上看得见、点得到:0.8.1 里登录藏在「设置 › 城」,没登录的人
// 在主窗口上看不出这个应用可以登录。
//
// 它自己是一个视图,而且只跟 `CityStore` 的 `account` 这一样:侧栏所在的
// `MainShellView` 一重画就是整个窗口,而 `CityStore` 在日历刷新、交档案馆的
// 每一步都会发变化,那些跟这一行没有关系。

import SwiftUI

struct SidebarAccountRow: View {
    /// 这一行摆出来的样子。纯数据,可以单独测。
    enum Presentation: Equatable {
        case signedOut
        case signedIn(initial: String, name: String)

        static func resolve(_ account: FfiCityAccount?) -> Presentation {
            guard let account else { return .signedOut }
            let name = account.personName.trimmingCharacters(in: .whitespacesAndNewlines)
            return .signedIn(
                initial: CityText.initial(name),
                name: name.isEmpty ? String(localized: "city.settings.unnamed") : name
            )
        }
    }

    /// 打开「设置 › 账号」。
    var onOpen: () -> Void = {
        MainNavigationStore.shared.openSettings(section: .account)
    }

    @State private var presentation = Presentation.resolve(CityStore.shared.account)

    var body: some View {
        Button(action: onOpen) {
            SidebarAccountRowLabel(presentation: presentation)
        }
        .buttonStyle(.plain)
        .help(String(localized: "sidebar.account.hint"))
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(String(localized: "sidebar.account.hint")))
        .accessibilityIdentifier("sidebar.account")
        .onReceive(CityStore.shared.$account) { account in
            let next = Presentation.resolve(account)
            // 登录的人没变就不动:`account` 每次赋值都会发一次。
            if next != presentation { presentation = next }
        }
    }

    private var accessibilityLabel: String {
        switch presentation {
        case .signedOut: return String(localized: "sidebar.account.sign_in")
        case .signedIn(_, let name): return name
        }
    }
}

/// 那一行画出来的样子,只看传进来的数据。
struct SidebarAccountRowLabel: View {
    let presentation: SidebarAccountRow.Presentation

    var body: some View {
        HStack(spacing: Spacing.sm) {
            switch presentation {
            case .signedOut:
                // 和页脚别的几行一个写法(`Label`、同一个字号),图标和字才对得齐。
                Label(
                    String(localized: "sidebar.account.sign_in"),
                    systemImage: "person.crop.circle"
                )
                .font(.bodySM)
                .foregroundColor(.textSecondary)
            case .signedIn(let initial, let name):
                Text(initial)
                    .font(Font.sans11Semibold)
                    .foregroundColor(.brandAccentForeground)
                    .frame(width: 22, height: 22)
                    .background(Color.brandAccent)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(name)
                    .font(.bodySM)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
    }
}
