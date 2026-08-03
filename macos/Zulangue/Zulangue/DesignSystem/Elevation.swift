// Elevation.swift
// Zulangue 4 级 elevation 系统
// 权威:docs/redesign/redesign-plan.md §4.A.4
//
// 设计原则 6(原则 #6 from redesign-plan §2):
// Elevation 必须是分层系统,不是 shadow 堆砌。
//
// 4 级层级:
//   flat       (Library 主背景,无 shadow)
//   raised     (默认卡片,subtle shadow)
//   floating   (hover 卡片 / dropdown,medium shadow)
//   overlay    (Sheet / Popover,strong shadow + glass)
//
// 每级对应:
//   - 一个 bg 提亮量
//   - 一个 shadow 强度(色 + 半径 + Y 偏移)
//   - 一个 border 提亮量
//
// hover 时自动 elevation +1(需要的组件自行内置)。
// 禁止散落的 .shadow(color:radius:y:) 调用,统一用 .elevation(_:) modifier。

import SwiftUI

enum Elevation: Int, Comparable {
    case flat = 0       // 无 shadow,主背景
    case raised = 1     // 默认卡片
    case floating = 2   // hover 卡片 / dropdown
    case overlay = 3    // sheet / popover

    static func < (lhs: Elevation, rhs: Elevation) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 背景色
    var bg: Color {
        switch self {
        case .flat:     return .bgRoot
        case .raised:   return .bgSurface
        case .floating: return .bgElevated
        case .overlay:  return .bgGlass
        }
    }

    /// 阴影颜色(用 Color token,可被 dark/light mode 适配)
    var shadowColor: Color {
        switch self {
        case .flat:     return .clear
        case .raised:   return .shadowSubtle
        case .floating: return .shadowMedium
        case .overlay:  return .shadowStrong
        }
    }

    /// 阴影模糊半径
    var shadowRadius: CGFloat {
        switch self {
        case .flat:     return 0
        case .raised:   return 4
        case .floating: return 12
        case .overlay:  return 24
        }
    }

    /// 阴影 Y 偏移
    var shadowY: CGFloat {
        switch self {
        case .flat:     return 0
        case .raised:   return 2
        case .floating: return 4
        case .overlay:  return 8
        }
    }

    /// 边框色
    var border: Color {
        switch self {
        case .flat:     return .clear
        case .raised:   return .borderPanel
        case .floating: return .borderActive
        case .overlay:  return .borderActive
        }
    }

    /// hover 时自动升一级(到达 overlay 后保持)
    func hoverElevated() -> Elevation {
        Elevation(rawValue: rawValue + 1) ?? self
    }
}

// MARK: - View modifier

extension View {
    /// 统一的 elevation modifier
    /// 所有卡片/面板都用这个,不要散落 .shadow
    ///
    /// 用法:
    /// ```
    /// VStack { ... }
    ///     .elevation(.raised)            // 默认卡片
    ///     .elevation(.floating, cornerRadius: Radius.lg)  // hover 卡片大圆角
    /// ```
    func elevation(_ level: Elevation, cornerRadius: CGFloat = Radius.md) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(level.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(level.border, lineWidth: 1)
        )
        .shadow(
            color: level.shadowColor,
            radius: level.shadowRadius,
            y: level.shadowY
        )
    }
}
