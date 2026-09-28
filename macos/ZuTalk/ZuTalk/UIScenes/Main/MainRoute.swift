import Foundation

struct EditorRoute: Equatable, Sendable {
    let notebookID: String
    let tabID: String
    let documentID: String
    let selectedSessionID: String?
    /// Topic cards land on the Topic's Session workspace. Capture entry points
    /// still land on the realtime surface, even though both routes reuse the
    /// same durable builtin document underneath.
    let opensTopicWorkspace: Bool

    init(
        notebookID: String,
        tabID: String,
        documentID: String,
        selectedSessionID: String?,
        opensTopicWorkspace: Bool = false
    ) {
        self.notebookID = notebookID
        self.tabID = tabID
        self.documentID = documentID
        self.selectedSessionID = selectedSessionID
        self.opensTopicWorkspace = opensTopicWorkspace
    }
}

enum MainRoute: Equatable {
    case record
    case home
    case topics
    case trash
    case editor(route: EditorRoute, initialView: EditorInitialView)
    case settings

    var tab: MainTab {
        switch self {
        case .record:
            return .record
        case .home:
            return .home
        case .topics:
            return .topics
        case .trash:
            return .trash
        case .editor:
            return .editor
        case .settings:
            return .config
        }
    }
}
