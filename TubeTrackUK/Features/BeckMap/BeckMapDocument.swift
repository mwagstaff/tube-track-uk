import Foundation

/// Immutable, versioned artwork consumed by the Beck renderer.
///
/// This deliberately owns its geometry instead of retaining `TubeGraph`. A
/// future authoring tool can therefore replace one versioned artwork document
/// with another without changing the renderer.
struct BeckMapDocument: Codable, Hashable, Sendable {
    let schemaVersion: BeckMapSchemaVersion
    let identifier: String
    let geometryStatus: BeckMapGeometryStatus
    let source: BeckMapSourceRecord
    let artworkSize: BeckMapSize
    let styles: BeckMapStyleRecord
    let debugReference: BeckMapDebugReferenceRecord
    let paths: [BeckMapPathRecord]
    let segments: [BeckMapSegmentRecord]
    let stationMarkers: [BeckMapStationMarkerRecord]
    let labels: [BeckMapLabelRecord]
    let routes: [BeckMapRouteRecord]
}

struct BeckMapSchemaVersion: Codable, Hashable, Sendable {
    let major: Int
    let minor: Int

    static let first = Self(major: 1, minor: 0)
    static let current = Self(major: 1, minor: 2)
}

enum BeckMapGeometryStatus: String, Codable, Hashable, Sendable {
    case prototype
    case authored
}

struct BeckMapSourceRecord: Codable, Hashable, Sendable {
    let graphSchemaVersion: Int
    let graphGeneratedAt: String
    let note: String
}

struct BeckMapSize: Codable, Hashable, Sendable {
    let width: Double
    let height: Double
}

struct BeckMapStyleRecord: Codable, Hashable, Sendable {
    let routeStrokeWidth: Double
    let affectedOuterStrokeWidth: Double
    let affectedKnockoutStrokeWidth: Double
    let affectedRouteStrokeWidth: Double
    let primaryLabelFontSize: Double
    let secondaryLabelFontSize: Double
    let labelPadding: Double
}

struct BeckMapDebugReferenceRecord: Codable, Hashable, Sendable {
    let resourceName: String
    let resourceExtension: String
    let geometryOpacity: Double
}

struct BeckMapPoint: Codable, Hashable, Sendable {
    let x: Double
    let y: Double

    static let zero = Self(x: 0, y: 0)
}

struct BeckMapTranslation: Codable, Hashable, Sendable {
    let x: Double
    let y: Double

    static let zero = Self(x: 0, y: 0)
}

/// Explicit path vocabulary used by extracted artwork. Cubic handles are
/// stored permanently; the renderer never derives or smooths them.
enum BeckMapPathCommand: Codable, Hashable, Sendable {
    case move(to: BeckMapPoint)
    case line(to: BeckMapPoint)
    case cubic(control1: BeckMapPoint, control2: BeckMapPoint, to: BeckMapPoint)
    case close

    private enum Operation: String, Codable {
        case move
        case line
        case cubic
        case close
    }

    private enum CodingKeys: String, CodingKey {
        case operation = "op"
        case to
        case control1
        case control2
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Operation.self, forKey: .operation) {
        case .move:
            self = .move(to: try container.decode(BeckMapPoint.self, forKey: .to))
        case .line:
            self = .line(to: try container.decode(BeckMapPoint.self, forKey: .to))
        case .cubic:
            self = .cubic(
                control1: try container.decode(BeckMapPoint.self, forKey: .control1),
                control2: try container.decode(BeckMapPoint.self, forKey: .control2),
                to: try container.decode(BeckMapPoint.self, forKey: .to)
            )
        case .close:
            self = .close
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .move(to):
            try container.encode(Operation.move, forKey: .operation)
            try container.encode(to, forKey: .to)
        case let .line(to):
            try container.encode(Operation.line, forKey: .operation)
            try container.encode(to, forKey: .to)
        case let .cubic(control1, control2, to):
            try container.encode(Operation.cubic, forKey: .operation)
            try container.encode(control1, forKey: .control1)
            try container.encode(control2, forKey: .control2)
            try container.encode(to, forKey: .to)
        case .close:
            try container.encode(Operation.close, forKey: .operation)
        }
    }
}

struct BeckMapPathRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let commands: [BeckMapPathCommand]
}

enum BeckMapPathDirection: String, Codable, Hashable, Sendable {
    case forward
    case reverse
}

/// A semantic Tube segment references artwork by ID and applies only an
/// authored translation. Presentation state never mutates this record.
struct BeckMapSegmentRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let lineID: TubeLineID
    let fromStationID: String
    let toStationID: String
    /// Optional platform ports allow complex interchanges to keep one logical
    /// selection anchor while each line terminates at its traced artwork point.
    var fromPort: BeckMapPoint? = nil
    var toPort: BeckMapPoint? = nil
    let pathID: String
    let pathDirection: BeckMapPathDirection
    let translation: BeckMapTranslation
}

struct BeckMapLinePrimitive: Codable, Hashable, Sendable {
    let start: BeckMapPoint
    let end: BeckMapPoint
    let width: Double
}

/// An ordinary station mark is an authored stroke perpendicular to its route.
/// It carries its line colour explicitly because station artwork is rendered in
/// a later pass than the route paths.
struct BeckMapTickPrimitive: Codable, Hashable, Sendable {
    let lineID: TubeLineID
    let start: BeckMapPoint
    let end: BeckMapPoint
    let width: Double
}

struct BeckMapCirclePrimitive: Codable, Hashable, Sendable {
    let centre: BeckMapPoint
    let radius: Double
    let outlineWidth: Double
}

/// Station artwork is explicit so complex interchanges can later be traced as
/// circles and connector bars rather than inferred by the Canvas renderer.
enum BeckMapStationMarkerPrimitive: Codable, Hashable, Sendable {
    case connector(BeckMapLinePrimitive)
    case walkingConnector(BeckMapLinePrimitive)
    case circle(BeckMapCirclePrimitive)
    case tick(BeckMapTickPrimitive)

    private enum Kind: String, Codable {
        case connector
        case walkingConnector
        case circle
        case tick
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case connector
        case walkingConnector
        case circle
        case tick
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .connector:
            self = .connector(try container.decode(BeckMapLinePrimitive.self, forKey: .connector))
        case .walkingConnector:
            self = .walkingConnector(
                try container.decode(BeckMapLinePrimitive.self, forKey: .walkingConnector)
            )
        case .circle:
            self = .circle(try container.decode(BeckMapCirclePrimitive.self, forKey: .circle))
        case .tick:
            self = .tick(try container.decode(BeckMapTickPrimitive.self, forKey: .tick))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .connector(connector):
            try container.encode(Kind.connector, forKey: .kind)
            try container.encode(connector, forKey: .connector)
        case let .walkingConnector(connector):
            try container.encode(Kind.walkingConnector, forKey: .kind)
            try container.encode(connector, forKey: .walkingConnector)
        case let .circle(circle):
            try container.encode(Kind.circle, forKey: .kind)
            try container.encode(circle, forKey: .circle)
        case let .tick(tick):
            try container.encode(Kind.tick, forKey: .kind)
            try container.encode(tick, forKey: .tick)
        }
    }
}

struct BeckMapStationMarkerRecord: Codable, Identifiable, Hashable, Sendable {
    let stationID: String
    let name: String
    let lineIDs: [TubeLineID]
    let anchor: BeckMapPoint
    let hitRadius: Double
    let primitives: [BeckMapStationMarkerPrimitive]

    var id: String { stationID }
}

enum BeckMapLabelAlignment: String, Codable, Hashable, Sendable {
    case leading
    case centre
    case trailing
}

/// Labels keep an authored preferred position. The renderer preserves that
/// direction while enforcing screen-space clearance from map content.
struct BeckMapLabelRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let stationID: String
    let text: String
    let position: BeckMapPoint
    let alignment: BeckMapLabelAlignment
    let rotationDegrees: Double
    let priority: Int
}

struct BeckMapRouteRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let lineID: TubeLineID
    let stationIDs: [String]
    let segmentIDs: [String]
}
