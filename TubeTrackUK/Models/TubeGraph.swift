import CoreLocation
import Foundation

struct SchematicPoint: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
}

struct GeographicPoint: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct TubeStation: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let schematicX: Double
    let schematicY: Double
    let lineIDs: [TubeLineID]
    let interchange: Bool
    let searchAliases: [String]

    var schematicPoint: SchematicPoint {
        SchematicPoint(x: schematicX, y: schematicY)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct TubeSegment: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let lineID: TubeLineID
    let fromStationID: String
    let toStationID: String
    let schematicPoints: [SchematicPoint]
    let geographicPoints: [GeographicPoint]
}

struct TubeGraphLine: Codable, Identifiable, Hashable, Sendable {
    let id: TubeLineID
    let name: String
    let segmentIDs: [String]
    let routes: [[String]]
}

struct TubeGraphSize: Codable, Hashable, Sendable {
    let width: Double
    let height: Double
}

struct TubeGraphSource: Codable, Hashable, Sendable {
    let name: String
    let url: String
    let attribution: String
}

struct TubeGraph: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: String
    let source: TubeGraphSource
    let schematicSize: TubeGraphSize
    let stations: [TubeStation]
    let segments: [TubeSegment]
    let lines: [TubeGraphLine]

    var stationsByID: [String: TubeStation] {
        Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
    }

    var segmentsByID: [String: TubeSegment] {
        Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
    }

    func segments(for lineID: TubeLineID) -> [TubeSegment] {
        segments.filter { $0.lineID == lineID }
    }

    func line(_ id: TubeLineID) -> TubeGraphLine? {
        lines.first { $0.id == id }
    }

    static func bundled() throws -> TubeGraph {
        guard let url = Bundle.main.url(forResource: "TubeGraph", withExtension: "json") else {
            throw TubeGraphError.missingBundledGraph
        }
        let data = try Data(contentsOf: url)
        let graph = try JSONDecoder().decode(TubeGraph.self, from: data)
        guard graph.schemaVersion == 1 else {
            throw TubeGraphError.unsupportedSchema(graph.schemaVersion)
        }
        return graph
    }
}

enum TubeGraphError: LocalizedError {
    case missingBundledGraph
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .missingBundledGraph: "The bundled Tube network could not be found."
        case let .unsupportedSchema(version): "Tube network schema version \(version) is not supported."
        }
    }
}

