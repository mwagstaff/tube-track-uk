import CoreLocation
import Foundation

struct NearbyStation: Identifiable, Sendable {
    let station: TubeStation
    let distance: CLLocationDistance

    var id: String { station.id }
}

enum NearbyStationFinder {
    static func stationsByDistance(
        to location: CLLocation,
        in stations: [TubeStation]
    ) -> [NearbyStation] {
        Dictionary(grouping: stations) { $0.hubID ?? $0.id }
            .values
            .compactMap { colocatedStations -> NearbyStation? in
                colocatedStations
                    .map { station in
                        NearbyStation(
                            station: station,
                            distance: location.distance(from: CLLocation(
                                latitude: station.latitude,
                                longitude: station.longitude
                            ))
                        )
                    }
                    .min { left, right in
                        if left.distance != right.distance {
                            return left.distance < right.distance
                        }
                        return left.station.id < right.station.id
                    }
            }
            .sorted { left, right in
                if left.distance != right.distance {
                    return left.distance < right.distance
                }
                if left.station.name != right.station.name {
                    return left.station.name < right.station.name
                }
                return left.station.id < right.station.id
            }
    }

    static func nearestStations(
        to location: CLLocation,
        in stations: [TubeStation],
        limit: Int = 3
    ) -> [NearbyStation] {
        guard limit > 0 else { return [] }
        return stationsByDistance(to: location, in: stations)
            .prefix(limit)
            .map { $0 }
    }
}

enum NearbyDistanceFormatter {
    static func string(from distance: CLLocationDistance) -> String {
        if distance < 1_000 {
            return "\(max(1, Int(distance.rounded()))) m"
        }
        return String(format: "%.1f km", distance / 1_000)
    }
}
