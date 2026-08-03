// ReferenceNumber.swift
// 设计宪法 §06.2: REF-A-12 / VT-SES-010 / VT-001 编号标签
// Session 身份标识,贯穿整个产品

import SwiftUI

/// 编号显示组件。宪法级 primitive。
///
/// 例:
/// - REF-A-12        session 主编号
/// - VT-SES-010      session 会话级别名
/// - VT-001          app 实例编号
/// - DRAW-003        草稿编号
struct ReferenceNumber: View {

    enum Scope {
        case session(String)      // REF-A-{NNN}
        case sessionLong(String)  // VT-SES-{NNN}
        case app(String)          // VT-{NNN}
        case draft(String)        // DRAW-{NNN}
        case raw(String)          // 自定义,不加前缀

        var rendered: String {
            switch self {
            case .session(let id):     return "REF-A-\(id)"
            case .sessionLong(let id): return "VT-SES-\(id)"
            case .app(let id):         return "VT-\(id)"
            case .draft(let id):       return "DRAW-\(id)"
            case .raw(let s):          return s
            }
        }
    }

    let scope: Scope
    var size: Size = .body
    var emphasis: Emphasis = .gold

    enum Size {
        case caption  // 11pt
        case body     // 13pt
        case title    // 18pt
        case display  // 32pt
    }

    enum Emphasis {
        case gold      // 金色 (默认 · 身份感)
        case muted     // 灰 (列表次要)
        case orange    // 橙 (active)
        case onHw      // 硬件模式黑
        case onBp      // 蓝图模式白
    }

    var body: some View {
        Text(scope.rendered)
            .font(font)
            .tracking(tracking)
            .foregroundColor(color)
            .textCase(.uppercase)
    }

    private var font: Font {
        switch size {
        case .caption: return .captionMedium
        case .body:    return .dataMedium
        case .title:   return .titleMD
        case .display: return .displayLG
        }
    }

    private var tracking: CGFloat {
        switch size {
        case .caption: return 0.9
        case .body:    return 0.6
        case .title:   return 0.4
        case .display: return -0.3
        }
    }

    private var color: Color {
        switch emphasis {
        case .gold:   return .accentGold
        case .muted:  return .textTertiary
        case .orange: return .accentOrange
        case .onHw:   return .textPrimary
        case .onBp:   return .textPrimary
        }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ReferenceNumber(scope: .session("012"), size: .caption)
        ReferenceNumber(scope: .session("012"), size: .body)
        ReferenceNumber(scope: .session("012"), size: .title)
        ReferenceNumber(scope: .sessionLong("010"), size: .body, emphasis: .muted)
        ReferenceNumber(scope: .app("001"), size: .body, emphasis: .orange)
    }
    .padding(32)
    .background(Color.bgRoot)
}
#endif
