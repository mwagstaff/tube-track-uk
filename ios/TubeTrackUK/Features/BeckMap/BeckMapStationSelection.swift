import SwiftUI

/// Selection follows the station hub and the circles and ticks drawn on the map.
/// Semantic anchors can be well away from a service's visible symbol.
struct BeckMapStationSelection {
    struct Roundel: Equatable {
        let centre: BeckMapPoint
        let radius: Double
    }

    let roundels: [Roundel]
    let usesReferenceRoundels: Bool

    static func stationIDs(for selectedStationID: String?, in graph: TubeGraph) -> Set<String> {
        guard let selectedStationID else { return [] }
        guard let station = graph.stationsByID[selectedStationID] else { return [selectedStationID] }
        return Set(graph.stations(inSamePlaceAs: station).map(\.id))
    }

    init(document: BeckMapDocument, stationIDs: Set<String>) {
        guard !stationIDs.isEmpty else {
            roundels = []
            usesReferenceRoundels = false
            return
        }
        let referenceRoundels = (document.referenceArtwork?.stationRoundels ?? [])
            .filter { stationIDs.contains($0.stationID) }
        let referenceTicks = (document.referenceArtwork?.stationTicks ?? [])
            .filter { stationIDs.contains($0.stationID) }
        usesReferenceRoundels = !referenceRoundels.isEmpty || !referenceTicks.isEmpty
        var candidates: [Roundel]
        if usesReferenceRoundels {
            candidates = referenceRoundels.map { Roundel(centre: $0.centre, radius: $0.radius) }
                + referenceTicks.map { Roundel(centre: $0.centre, radius: 0) }
        } else {
            let markers = document.stationMarkers.filter { stationIDs.contains($0.stationID) }
            candidates = markers.flatMap { marker in
                marker.primitives.compactMap { primitive in
                    guard case let .circle(circle) = primitive else { return nil }
                    return Roundel(centre: circle.centre, radius: circle.radius + circle.outlineWidth / 2)
                }
            }
            // Ordinary tick stations still need a selection indicator.
            if candidates.isEmpty {
                candidates = markers.flatMap { marker in
                    marker.primitives.compactMap { primitive in
                        guard case let .tick(tick) = primitive else { return nil }
                        return Roundel(centre: BeckMapPoint(x: (tick.start.x + tick.end.x) / 2,
                                                           y: (tick.start.y + tick.end.y) / 2), radius: 0)
                    }
                }
                if candidates.isEmpty { candidates = markers.map { Roundel(centre: $0.anchor, radius: 0) } }
            }
        }

        // Shared interchange circles can belong to several station records.
        // Draw each physical circle once so its highlight does not get darker.
        var unique: [Roundel] = []
        for candidate in candidates {
            if let index = unique.firstIndex(where: {
                hypot($0.centre.x - candidate.centre.x, $0.centre.y - candidate.centre.y) < 0.1
            }) {
                if candidate.radius > unique[index].radius { unique[index] = candidate }
            } else {
                unique.append(candidate)
            }
        }
        roundels = unique
    }

    func haloPath(cameraScale: CGFloat) -> Path {
        let scale = max(cameraScale, 0.01)
        var path = Path()
        for roundel in roundels {
            // Keep the familiar touch-sized halo, expanding it at high zoom so
            // it always surrounds the complete visible station circle.
            let radius = max(19 / scale, roundel.radius + 3 / scale)
            path.addEllipse(in: CGRect(
                x: roundel.centre.x - radius, y: roundel.centre.y - radius,
                width: radius * 2, height: radius * 2
            ))
        }
        return path
    }

    func draw(context: inout GraphicsContext, cameraScale: CGFloat) {
        let path = haloPath(cameraScale: cameraScale)
        // A single fill avoids stacking translucent blue where halos overlap.
        context.fill(path, with: .color(Color.blue.opacity(0.16)))
        context.stroke(path, with: .color(Color.blue.opacity(0.9)),
                       lineWidth: 2.5 / max(cameraScale, 0.01))
    }
}
