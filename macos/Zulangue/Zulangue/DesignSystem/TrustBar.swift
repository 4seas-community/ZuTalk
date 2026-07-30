// TrustBar.swift
// 底部信任条 — 每个页面底部贯穿
// 视觉原则：design-system/MASTER.md

import SwiftUI

// MARK: - TrustBar

/// 底部信任条
///
/// 显示本地加密、本机密钥存储与远端显式启用的信任边界
/// 每个页面/视图的底部都存在
struct TrustBar: View {
    var indicators: [TrustIndicator.Model] = TrustIndicator.defaults

    var body: some View {
        HStack {
            HStack(spacing: Spacing.lg) {
                ForEach(indicators, id: \.label) { model in
                    TrustIndicator(model: model)
                }
            }

            Spacer()

            // 右侧：版本号 + Session 数等
            let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
            Text(String(format: String(localized: "trust.version_format"), version))
                .font(Font.mono9)
                .foregroundColor(Color.textDim)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .frame(height: 28)
        .background(Color.bgRoot)
        .overlay(
            Rectangle()
                .fill(Color.borderSubtle)
                .frame(height: 1),
            alignment: .top
        )
    }
}

// MARK: - TrustIndicator

/// 信任条内的单个指示器（dot + text）
struct TrustIndicator: View {
    struct Model {
        let label: String
        var color: Color = .signalGreen
        var textColor: Color = .signalGreenText
    }

    let model: Model

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.color)
                .frame(width: 4, height: 4)
            Text(model.label)
                .font(Font.mono9)
                .foregroundColor(model.textColor)
        }
    }

    /// 默认信任指示器（每个页面底部）
    static var defaults: [Model] {
        [
            Model(label: String(localized: "trust.label.aes")),
            Model(label: String(localized: "trust.label.local_secrets")),
            Model(label: String(localized: "trust.label.remote_opt_in")),
        ]
    }
}

// MARK: - Preview

#if DEBUG
struct TrustBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            Spacer()
            TrustBar()
        }
        .frame(width: 800, height: 200)
        .background(Color.bgRoot)
    }
}
#endif
