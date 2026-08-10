import Foundation

struct EditorRoute: Equatable {
    let notebookID: String
    let tabID: String
    let documentID: String
    let selectedSessionID: String?
}

enum MainRoute: Equatable {
    case home
    case knowledge
    case trash
    case share
    case editor(route: EditorRoute, initialView: EditorInitialView)
    case settings

    var tab: MainTab {
        switch self {
        case .home:
            return .home
        case .knowledge:
            return .knowledge
        case .trash:
            return .trash
        case .share:
            return .share
        case .editor:
            return .editor
        case .settings:
            return .config
        }
    }
}
