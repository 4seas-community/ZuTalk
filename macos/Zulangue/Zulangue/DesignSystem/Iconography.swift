// Iconography.swift
// Zulangue 图标系统命名常量
// 权威:docs/redesign/redesign-plan.md §4.A.6
//
// 设计原则:
// - SF Symbols 用法集中管理,不要在 view 里写 magic string
// - 每个 icon 有语义名(Icon.record),不是图形描述(record.circle.fill)
// - 字号字重提供 helper modifier(iconSizeSmall/Medium/Large)
// - 替换的目的是让"换 icon"成为一个集中决策,而不是 grep 全项目

import SwiftUI

enum Icon {

    // MARK: - 菜单栏 popover Quick Actions

    static let float    = "rectangle.on.rectangle"  // Open live captions panel
    static let record   = "record.circle.fill"      // Start recording
    static let library  = "books.vertical.fill"     // Open library
    static let settings = "gearshape.fill"          // Settings

    // MARK: - 录音控制

    static let stop     = "stop.circle.fill"
    static let pause    = "pause.circle.fill"
    static let play     = "play.circle.fill"
    static let mic      = "mic.fill"
    static let micOff   = "mic.slash.fill"

    // MARK: - Library

    static let pin       = "pin.fill"
    static let pinOff    = "pin.slash.fill"
    static let tag       = "tag.fill"
    static let trash     = "trash.fill"
    static let search    = "magnifyingglass"
    static let filter    = "line.3.horizontal.decrease.circle"
    static let folder    = "folder.fill"
    static let plus      = "plus.circle.fill"
    static let dragImport = "arrow.down.doc.fill"

    // MARK: - Session Detail

    static let transcript = "doc.text"
    static let summary    = "doc.text.magnifyingglass"
    static let audio      = "waveform"
    static let edit       = "pencil"
    static let copy       = "doc.on.doc"
    static let export     = "square.and.arrow.up"

    // MARK: - 状态指示

    static let connected   = "checkmark.circle.fill"
    static let connecting  = "ellipsis.circle"
    static let disconnected = "wifi.exclamationmark"
    static let error       = "exclamationmark.triangle.fill"
    static let warning     = "exclamationmark.circle.fill"
    static let info        = "info.circle.fill"
    static let lock        = "lock.fill"
    static let lockOpen    = "lock.open.fill"

    // MARK: - 导航

    static let chevronRight = "chevron.right"
    static let chevronDown  = "chevron.down"
    static let chevronUp    = "chevron.up"
    static let xmark        = "xmark"
    static let xmarkCircle  = "xmark.circle.fill"
}

// MARK: - 默认字号字重 modifier

extension Image {
    /// 小尺寸 icon(12pt) — 用于行内文字旁的辅助图标
    func iconSizeSmall() -> some View {
        self.font(.system(size: 12, weight: .medium))
    }

    /// 中尺寸 icon(14pt) — 用于按钮 / Tab / List 行
    func iconSizeMedium() -> some View {
        self.font(.system(size: 14, weight: .semibold))
    }

    /// 大尺寸 icon(16pt) — 用于强调元素
    func iconSizeLarge() -> some View {
        self.font(.system(size: 16, weight: .semibold))
    }

    /// 超大尺寸 icon(48pt) — 用于 EmptyState
    func iconSizeHero() -> some View {
        self.font(.system(size: 48, weight: .light))
    }
}
