import MapKit
import SwiftUI

struct GeographicRiverBoats: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let proxy: MapProxy

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 30 : 1)) { timeline in
            Canvas { context, size in
                let river = appState.river
                var image = context.resolve(Image(systemName: "ferry.fill"))
                image.shading = .color(.blue)
                let visibleBounds = CGRect(origin: .zero, size: size).insetBy(dx: -12, dy: -12)
                for boat in river.filteredBoats {
                    guard let coordinate = river.boatCoordinate(for: boat, at: timeline.date),
                          let point = proxy.convert(coordinate, to: .local) else { continue }
                    guard visibleBounds.contains(point) else { continue }
                    context.draw(image, in: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityRepresentation {
            ForEach(appState.river.filteredBoats.filter { $0.progress(at: .now) != nil }) { boat in
                Button("Estimated \(boat.lineId.uppercased()) boat, next pier \(appState.river.network.pier(boat.nextPierId)?.name ?? "Unknown")") {
                    appState.select(boat: boat)
                }
            }
        }
    }
}

struct RiverGeographicSegment: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
}

extension RiverBusState {
    func boatCoordinate(for boat: EstimatedRiverBoat, at date: Date) -> CLLocationCoordinate2D? {
        guard let progress = boat.progress(at: date),
              let from = network.pier(boat.previousPierId), let to = network.pier(boat.nextPierId),
              let point = geographicBoatPaths.path(from: from.id, to: to.id, build: {
                  geometry.path(from: from, to: to)
              }).point(at: progress) else { return nil }
        return MKMapPoint(x: point.x, y: point.y).coordinate
    }

    var geographicSegments: [RiverGeographicSegment] {
        guard let selectedLineId else { return [] }
        if let cachedGeographicSegments { return cachedGeographicSegments }
        var seen = Set<String>()
        let result: [RiverGeographicSegment] = network.routes.filter { $0.lineId == selectedLineId }.flatMap { route in
            zip(route.stopIds, route.stopIds.dropFirst()).compactMap { a, b in
                let id = [a, b].sorted().joined(separator: ":")
                guard seen.insert(id).inserted, let from = network.pier(a), let to = network.pier(b) else { return nil }
                let coordinates = geometry.path(from: from, to: to).map { MKMapPoint(x: $0.x, y: $0.y).coordinate }
                guard coordinates.count >= 2 else { return nil }
                return RiverGeographicSegment(id: id, coordinates: coordinates)
            }
        }
        cachedGeographicSegments = result
        return result
    }
}
