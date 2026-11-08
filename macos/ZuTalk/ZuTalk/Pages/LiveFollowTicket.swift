import Foundation

/// The pending tail scroll of a live transcript, kept outside SwiftUI state.
///
/// Its fields are bookkeeping that nothing displays. They used to be @State,
/// so every scroll-geometry callback that cancelled or scheduled a follow
/// invalidated the whole view; its relayout moved the scroll geometry again,
/// which called back again. SwiftUI reported the loop as "tried to update
/// multiple times per frame", and it is the leading suspect for a main thread
/// that froze for 23 seconds when a recording's window came back from behind
/// a full-screen app. Held as one reference in @State, the instance lives as
/// long as the view and changing it redraws nothing.
@MainActor
final class LiveFollowTicket {
    var task: Task<Void, Never>?
    var generation: UInt64 = 0

    /// Drops any pending follow; a running one sees its generation retired.
    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}

enum LiveScrollGeometry {
    /// Scroll geometry to the whole point. A lazy stack refines its row-height
    /// estimates by fractions of a point as it lays out; reporting those
    /// fractions called the follow logic back for movement nobody could see.
    static func whole(_ value: CGFloat) -> Double {
        Double(value.rounded())
    }
}
