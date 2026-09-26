import MapKit
import SwiftUI

struct StationDirectionsButton: View {
    let station: TubeStation
    var iconOnly = false

    var body: some View {
        StopDirectionsButton(name: station.name, latitude: station.latitude,
                             longitude: station.longitude, iconOnly: iconOnly)
    }
}

struct StopDirectionsButton: View {
    @Environment(TubeAppState.self) private var appState
    let name: String
    let latitude: Double
    let longitude: Double
    var iconOnly = false
    var walking = false

    var body: some View {
        Button {
            openDirections()
        } label: {
            if iconOnly {
                Image(systemName: "arrow.triangle.turn.up.right.diamond")
                    .font(.appSubheadline(.semibold))
            } else {
                Label(
                    "Directions",
                    systemImage: "arrow.triangle.turn.up.right.diamond"
                )
                .font(.appCaption(.semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
        .accessibilityLabel("Get directions to \(name)")
        .requiresNetwork(appState.isOffline, onlineHint: walking ? "Opens walking directions in Maps" : "Opens transit directions in Maps")
    }

    private func openDirections() {
        let destination = MKMapItem(
            location: CLLocation(latitude: latitude, longitude: longitude),
            address: nil
        )
        destination.name = name
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: walking ? MKLaunchOptionsDirectionsModeWalking : MKLaunchOptionsDirectionsModeTransit
        ])
    }
}
