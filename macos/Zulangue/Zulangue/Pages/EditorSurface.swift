import Foundation

/// Every surface the editor's content area can show.
///
/// This exists because the content area used to be decided by the boolean
/// combination of five scattered values — `showTranscript`,
/// `isShowingResources`, `presentedCaptureSettingsNotebookId`, the active
/// tab's `displayType`, and `selectedSessionID`. Seven or eight surfaces are
/// legal; the combination space is dozens. SwiftUI's `if / else if` chains
/// have no exhaustiveness check, so a missed combination compiled fine and
/// rendered a blank page at runtime. Two of them did: the async tab with no
/// session, and a document whose tabs have not loaded yet.
///
/// Adding a case here breaks every `switch` until it is handled, which is the
/// point. Do not add a `default`.
enum EditorSurface: Equatable, Hashable {
    /// Route carries no usable document id.
    case missingDocument

    /// Document is known but its tabs have not resolved yet. Distinct from
    /// `missingDocument`: this one is transient and resolves on its own.
    case tabsLoading(notebookId: String)

    /// Notebook-level overlays. Both sit above whatever tab is selected and
    /// return to it when dismissed.
    case captureSettings(notebookId: String)
    case resources(notebookId: String)

    /// Capture command centre. Reachable before the Notebook has any session,
    /// which is why the session id is optional here and nowhere else.
    case realtime(notebookId: String, sessionId: String?)

    /// A finished post-stop transcript.
    case asyncTranscript(
        notebookId: String,
        sessionId: String,
        tabId: String,
        status: NotebookTabStatus
    )
    case asyncPending(notebookId: String, tabId: String)
    case asyncFailed(notebookId: String, tabId: String)

    /// The async tab reached without a session. The transcript layer is
    /// session-scoped, so before this case existed nothing claimed the state
    /// and the page rendered empty.
    case asyncNeedsSession(notebookId: String)

    /// Personal notes: the whole Notebook's timeline, or one note open.
    case manualTimeline(notebookId: String, tabId: String)
    case manualNote(notebookId: String, tabId: String)
}

extension EditorSurface {
    /// True while a transcript view is the visible surface.
    var showsTranscriptLayer: Bool {
        switch self {
        case .realtime, .asyncTranscript:
            return true
        case .missingDocument, .tabsLoading, .captureSettings,
             .resources, .asyncPending, .asyncFailed, .asyncNeedsSession,
             .manualTimeline, .manualNote:
            return false
        }
    }

    /// True while a Notebook-level overlay covers the tab content.
    var showsNotebookOverlay: Bool {
        switch self {
        case .captureSettings, .resources:
            return true
        case .missingDocument, .tabsLoading, .realtime,
             .asyncTranscript, .asyncPending, .asyncFailed, .asyncNeedsSession,
             .manualTimeline, .manualNote:
            return false
        }
    }
}

/// Resolves the visible surface from route, tab and overlay state.
///
/// Pure by design: the combination table is a unit test rather than something
/// discovered by clicking through the app.
enum EditorSurfacePolicy {
    static func resolve(
        route: EditorRoute?,
        activeTab: NotebookTabViewModel?,
        presentedCaptureSettingsNotebookId: String?,
        isShowingResources: Bool
    ) -> EditorSurface {
        guard let route, route.documentID.isEmpty == false else {
            return .missingDocument
        }
        let notebookId = route.notebookID

        // Overlays win over tab content: both are opened explicitly and both
        // restore the tab underneath when dismissed.
        if let presented = presentedCaptureSettingsNotebookId, presented == notebookId {
            return .captureSettings(notebookId: notebookId)
        }
        if isShowingResources {
            return .resources(notebookId: notebookId)
        }

        guard let activeTab else {
            return .tabsLoading(notebookId: notebookId)
        }

        let sessionId = route.selectedSessionID
        switch activeTab.displayType {
        case .realtimeTranscript:
            return .realtime(notebookId: notebookId, sessionId: sessionId)

        case .asyncTranscript:
            switch activeTab.status {
            case .pending:
                return .asyncPending(notebookId: notebookId, tabId: activeTab.tabId)
            case .failed:
                return .asyncFailed(notebookId: notebookId, tabId: activeTab.tabId)
            case .ready, .live:
                guard let sessionId else {
                    return .asyncNeedsSession(notebookId: notebookId)
                }
                return .asyncTranscript(
                    notebookId: notebookId,
                    sessionId: sessionId,
                    tabId: activeTab.tabId,
                    status: activeTab.status
                )
            }

        case .manualNote:
            return sessionId == nil
                ? .manualTimeline(notebookId: notebookId, tabId: activeTab.tabId)
                : .manualNote(notebookId: notebookId, tabId: activeTab.tabId)
        }
    }
}
