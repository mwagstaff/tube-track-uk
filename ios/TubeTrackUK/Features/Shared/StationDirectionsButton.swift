import MapKit
import SwiftUI

struct StationDirectionsButton: View {
    let station: TubeStation
    var iconOnly = false

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
        .accessibilityLabel("Get directions to \(station.name)")
        .accessibilityHint("Opens transit directions in Maps")
    }

    private func openDirections() {
        let destination = MKMapItem(
            location: CLLocation(latitude: station.latitude, longitude: station.longitude),
            address: nil
        )
        destination.name = station.name
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit
        ])
    }
}
