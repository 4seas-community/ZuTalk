import Foundation

enum WindowSurfaceID: String, CaseIterable {
    case main
    case subtitleOverlay

    var role: String {
        switch self {
        case .main:
            return "main"
        case .subtitleOverlay:
            return "subtitle-overlay"
        }
    }
}
