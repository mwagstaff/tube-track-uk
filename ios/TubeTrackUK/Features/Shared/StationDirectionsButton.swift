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

struct DepartureDistanceButton: View {
    @Environment(\.openURL) private var openURL
    let stop: DepartureStop
    let distance: Double?

    var body: some View {
        Button {
            guard let url = DepartureDirections.url(latitude: stop.latitude, longitude: stop.longitude) else { return }
            openURL(url) { accepted in
                if !accepted {
                    let destination = MKMapItem(location: CLLocation(latitude: stop.latitude, longitude: stop.longitude), address: nil)
                    destination.name = stop.name
                    destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey:
                        (distance ?? .infinity) < 1_609.344 ? MKLaunchOptionsDirectionsModeWalking : MKLaunchOptionsDirectionsModeTransit])
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: proximitySymbol)
                Text(distance.map { "\(NearbyDistanceFormatter.string(from: $0)) · Get directions" } ?? "Get directions")
                Image(systemName: "arrow.up.right").imageScale(.small)
            }
            .font(.appCaption())
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(distance.map { "\(NearbyDistanceFormatter.string(from: $0)) from \(stop.name). Get directions" } ?? "Directions to \(stop.name)")
        .accessibilityHint("Opens directions in your default maps app. Distance is in a straight line.")
    }

    private var proximitySymbol: String {
        guard let distance else { return "location" }
        if distance < 160 { return "mappin.circle.fill" }
        if distance < 805 { return "figure.walk" }
        if distance < 1_609.344 { return "figure.walk.circle" }
        return "arrow.triangle.turn.up.right.diamond"
    }
}

enum DepartureDirections {
    static func url(latitude: Double, longitude: Double) -> URL? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        var components = URLComponents()
        components.scheme = "geo-navigation"
        components.host = ""
        components.path = "/directions"
        components.queryItems = [URLQueryItem(name: "destination", value: "\(latitude),\(longitude)")]
        return components.url
    }
}
