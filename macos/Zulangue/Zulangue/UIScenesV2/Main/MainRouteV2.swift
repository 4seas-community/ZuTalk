import Foundation

struct EditorRouteV2: Equatable {
    let notebookID: String
    let tabID: String
    let documentID: String
    let selectedSessionID: String?
}

enum MainRouteV2: Equatable {
    case home
    case trash
    case editor(route: EditorRouteV2, initialView: EditorInitialView)
    case settings

    var tab: MainTab {
        switch self {
        case .home:
            return .home
        case .trash:
            return .trash
        case .editor:
            return .editor
        case .settings:
            return .config
        }
    }
}
