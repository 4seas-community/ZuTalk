import Combine
import Foundation
import Network

/// Whether this Mac has a network route at all, for the places that should
/// say "no network" up front instead of letting a request fail and blaming
/// the service it was addressed to.
///
/// A collaborator once recorded with live captions on a Mac that was not
/// online. Nothing on screen said so: the invite path reported "community
/// service unavailable", fell back to a saved personal key, and captions sat
/// at "connecting". The service and Soniox were both fine.
///
/// `NWPathMonitor` reports `.unsatisfied` only when no interface can carry
/// traffic. A captive portal or a dead upstream still reads `.satisfied`, so
/// `isOffline` is a strong claim the interface may state plainly, while
/// `isOffline == false` proves nothing about reaching any particular host.
/// `.requiresConnection` (an on-demand VPN, say) is not treated as offline
/// either: the system may bring that path up by itself.
@MainActor
final class NetworkReachability: ObservableObject {
    static let shared = NetworkReachability()

    /// Starts false so a Mac that is online never flashes a warning while
    /// the first path update is on its way.
    @Published private(set) var isOffline = false

    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let offline = path.status == .unsatisfied
            Task { @MainActor in
                NetworkReachability.shared.update(offline: offline)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        self.monitor = monitor
    }

    private func update(offline: Bool) {
        // Path updates also arrive for changes that do not flip reachability
        // (a new interface, a cost change); republishing those would redraw
        // every observer for nothing.
        guard isOffline != offline else { return }
        isOffline = offline
    }

    #if DEBUG
    func setOfflineForTesting(_ offline: Bool) {
        isOffline = offline
    }
    #endif
}
