import Foundation
import Network

/// Observes all interfaces, including switching between Wi-Fi and cellular.
@MainActor
final class NetworkConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private var started = false

    func start(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let isConnected = path.status == .satisfied
            Task { @MainActor in
                onChange(isConnected)
            }
        }
        monitor.start(queue: DispatchQueue(label: "TubeTrackUK.connectivity"))
    }

    deinit {
        monitor.cancel()
    }
}
