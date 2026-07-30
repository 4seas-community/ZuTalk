import Foundation

enum WindowSurfaceID: String, CaseIterable {
    case main
    case floatingPanel
    case captionMirror
    case operatorPanel

    var role: String {
        switch self {
        case .main:
            return "main"
        case .floatingPanel:
            return "floating-panel"
        case .captionMirror:
            return "caption-mirror"
        case .operatorPanel:
            return "operator-panel"
        }
    }
}
