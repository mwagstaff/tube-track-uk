import Foundation

/// Destination bearings use four board labels. Diagonal bearings join north
/// or south, so Ladywell–Charing Cross and Kent House–Orpington retain the
/// expected Northbound/Southbound labels. App and push projections share
/// these rules and the same station coordinates.
public enum NationalRailDirection {
    private struct Resource: Decodable, Sendable {
        let coordinatesByStation: [String: [Double]]
    }

    private static let resource: Resource? = {
        guard let url = Bundle.module.url(forResource: "NationalRailDirections", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Resource.self, from: data)
    }()

    public static func resolve(station: String, destinations: [String]) -> DepartureDirectionFilter? {
        guard let coordinates = resource?.coordinatesByStation,
              let start = coordinates[normalized(station)], start.count == 2,
              !destinations.isEmpty else { return nil }
        let directions = destinations.map { destination -> DepartureDirectionFilter? in
            guard let end = coordinates[normalized(destination)], end.count == 2,
                  start != end else { return nil }
            let latitude = start[0] * .pi / 180
            let destinationLatitude = end[0] * .pi / 180
            let longitudeDelta = (end[1] - start[1]) * .pi / 180
            let east = sin(longitudeDelta) * cos(destinationLatitude)
            let north = cos(latitude) * sin(destinationLatitude)
                - sin(latitude) * cos(destinationLatitude) * cos(longitudeDelta)
            let bearing = (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            switch bearing {
            case 67.5..<112.5: return .eastbound
            case 112.5..<247.5: return .southbound
            case 247.5..<292.5: return .westbound
            default: return .northbound
            }
        }
        // Every portion of a dividing service must have a known, matching direction.
        guard let direction = directions.first ?? nil,
              directions.allSatisfy({ $0 == direction }) else { return nil }
        return direction
    }

    private static func normalized(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
