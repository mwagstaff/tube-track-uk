import SwiftUI

extension View {
    /// Keeps unavailable actions visible while making their offline state clear.
    func requiresNetwork(_ isOffline: Bool, onlineHint: String = "") -> some View {
        disabled(isOffline)
            .opacity(isOffline ? 0.4 : 1)
            .accessibilityHint(isOffline ? "Requires an internet connection" : onlineHint)
    }
}
