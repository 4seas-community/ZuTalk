import Foundation

enum WindowSurfaceID: String, CaseIterable {
    case main
    case subtitleOverlay
    /// 放大的共享二维码:投到会场的大屏上,或者转过去给前排的人扫。
    case shareCode
    /// 看附近一台 ZuTalk 的直播字幕(同一网络,不经服务器)。
    case nearbyLive

    var role: String {
        switch self {
        case .main:
            return "main"
        case .subtitleOverlay:
            return "subtitle-overlay"
        case .shareCode:
            return "share-code"
        case .nearbyLive:
            return "nearby-live"
        }
    }
}
