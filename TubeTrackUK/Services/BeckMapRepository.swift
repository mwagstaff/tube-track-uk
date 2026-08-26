import Foundation

enum BeckMapRegion: String, CaseIterable, Identifiable, Sendable {
    case fullUnderground = "full-underground"
    case easternFan = "eastern-fan"
    case centralCompletion = "central-completion"
    case centralCoreJoin = "central-core-join"
    case eastConnector = "east-connector"
    case northConnector = "north-connector"
    case northwestConnector = "northwest-connector"
    case westernFan = "western-fan"
    case southConnector = "south-connector"
    case centralBackbone = "central-backbone"
    case westConnector = "west-connector"
    case heathrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullUnderground: "Full"
        case .easternFan: "Eastern fan"
        case .centralCompletion: "Central completion"
        case .centralCoreJoin: "Core"
        case .eastConnector: "East"
        case .northConnector: "North"
        case .northwestConnector: "Northwest"
        case .westernFan: "Western fan"
        case .southConnector: "South"
        case .centralBackbone: "Central"
        case .westConnector: "West"
        case .heathrow: "Heathrow"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .fullUnderground: "Complete Tube, DLR, Elizabeth, London Overground and London Trams map in one authored TfL design space"
        case .easternFan: "Eastern Underground branches traced from the official TfL vector map"
        case .centralCompletion: "Final central Underground joins traced from the official TfL vector map"
        case .centralCoreJoin: "Central core join traced from the official TfL vector map"
        case .eastConnector: "East London connector traced from the official TfL vector map"
        case .northConnector: "North London connector traced from the official TfL vector map"
        case .northwestConnector: "Northwest London connector traced from the official TfL vector map"
        case .westernFan: "Western Underground branches traced from the official TfL vector map"
        case .southConnector: "South London connector traced from the official TfL vector map"
        case .centralBackbone: "Central London authored Beck map slice"
        case .westConnector: "West London authored Beck map slice"
        case .heathrow: "Heathrow authored Beck map slice"
        }
    }
}

/// Loads immutable, authored Beck artwork and rejects geometry that has drifted
/// from the app's semantic Tube graph.
struct BeckMapRepository {
    static let supplementalHeathrowSegmentID = "piccadilly:940GZZLUHNX:940GZZLUHR4"

    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func load(region: BeckMapRegion = .heathrow, graph: TubeGraph) throws -> BeckMapDocument {
        let resourceURL = try resourceURL(for: region)
        let data: Data
        do {
            data = try Data(contentsOf: resourceURL)
        } catch {
            throw BeckMapRepositoryError.unreadableResource(
                path: resourceURL.path,
                reason: error.localizedDescription
            )
        }
        return try decode(data, against: graph)
    }

    func decode(_ data: Data, against graph: TubeGraph) throws -> BeckMapDocument {
        let document: BeckMapDocument
        do {
            document = try JSONDecoder().decode(BeckMapDocument.self, from: data)
        } catch {
            throw BeckMapRepositoryError.decodingFailed(reason: error.localizedDescription)
        }
        try validate(document, against: graph)
        return document
    }

    func validate(_ document: BeckMapDocument, against graph: TubeGraph) throws {
        guard document.schemaVersion == .current else {
            throw invalid(.unsupportedSchema(document.schemaVersion))
        }
        guard document.geometryStatus == .authored else {
            throw invalid(.geometryIsNotAuthored(document.geometryStatus))
        }
        guard document.source.graphSchemaVersion == graph.schemaVersion else {
            throw invalid(.graphSchemaMismatch(
                expected: graph.schemaVersion,
                actual: document.source.graphSchemaVersion
            ))
        }

        let canvas = document.artworkSize
        guard canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0 else {
            throw invalid(.invalidArtworkSize(canvas))
        }

        let styles = document.styles
        try validatePositive(styles.routeStrokeWidth, context: "route stroke width")
        try validatePositive(styles.affectedOuterStrokeWidth, context: "affected outer stroke width")
        try validatePositive(styles.affectedKnockoutStrokeWidth, context: "affected knockout stroke width")
        try validatePositive(styles.affectedRouteStrokeWidth, context: "affected route stroke width")
        try validatePositive(styles.primaryLabelFontSize, context: "primary label font size")
        try validatePositive(styles.secondaryLabelFontSize, context: "secondary label font size")
        try validatePositive(styles.labelPadding, context: "label padding")
        guard styles.affectedOuterStrokeWidth > styles.affectedKnockoutStrokeWidth,
              styles.affectedKnockoutStrokeWidth > styles.affectedRouteStrokeWidth,
              styles.affectedRouteStrokeWidth >= styles.routeStrokeWidth else {
            throw invalid(.invalidStyleOrdering)
        }

        try validateIdentifier(document.debugReference.resourceName, kind: "debug reference resource")
        try validateIdentifier(document.debugReference.resourceExtension, kind: "debug reference extension")
        guard document.debugReference.geometryOpacity.isFinite,
              (0 ... 1).contains(document.debugReference.geometryOpacity) else {
            throw invalid(.invalidOpacity(document.debugReference.geometryOpacity))
        }

        try validateIdentifier(document.identifier, kind: "document")
        try validateUnique(document.paths.map(\.id), kind: "path")
        try validateUnique(document.segments.map(\.id), kind: "segment")
        try validateUnique(document.stationMarkers.map(\.stationID), kind: "station marker")
        try validateUnique(document.labels.map(\.id), kind: "label")
        try validateUnique(document.routes.map(\.id), kind: "route")

        for path in document.paths {
            try validate(path: path, in: canvas)
        }

        let pathsByID = Dictionary(uniqueKeysWithValues: document.paths.map { ($0.id, $0) })
        let segmentsByID = Dictionary(uniqueKeysWithValues: document.segments.map { ($0.id, $0) })
        let markersByID = Dictionary(uniqueKeysWithValues: document.stationMarkers.map { ($0.stationID, $0) })
        let markerIDs = Set(document.stationMarkers.map(\.stationID))
        let graphStations = graph.stationsByID
        let graphSegments = graph.segmentsByID

        for segment in document.segments {
            try validateIdentifier(segment.fromStationID, kind: "segment station")
            try validateIdentifier(segment.toStationID, kind: "segment station")
            guard segment.fromStationID != segment.toStationID else {
                throw invalid(.segmentHasIdenticalEndpoints(segmentID: segment.id))
            }
            guard let path = pathsByID[segment.pathID] else {
                throw invalid(.missingPath(segmentID: segment.id, pathID: segment.pathID))
            }
            guard graphStations[segment.fromStationID] != nil else {
                throw invalid(.unknownStation(segment.fromStationID, context: "segment \(segment.id)"))
            }
            guard graphStations[segment.toStationID] != nil else {
                throw invalid(.unknownStation(segment.toStationID, context: "segment \(segment.id)"))
            }
            guard markerIDs.contains(segment.fromStationID) else {
                throw invalid(.missingStationMarker(
                    stationID: segment.fromStationID,
                    context: "segment \(segment.id)"
                ))
            }
            guard markerIDs.contains(segment.toStationID) else {
                throw invalid(.missingStationMarker(
                    stationID: segment.toStationID,
                    context: "segment \(segment.id)"
                ))
            }
            try validate(translation: segment.translation, segmentID: segment.id)
            if let fromPort = segment.fromPort {
                try validate(point: fromPort, context: "segment \(segment.id) from port", in: canvas)
            }
            if let toPort = segment.toPort {
                try validate(point: toPort, context: "segment \(segment.id) to port", in: canvas)
            }
            try validateTranslatedCoordinates(
                of: path,
                by: segment.translation,
                segmentID: segment.id,
                in: canvas
            )
            if let fromMarker = markersByID[segment.fromStationID],
               let toMarker = markersByID[segment.toStationID] {
                try validatePathEndpoints(
                    of: segment,
                    path: path,
                    fromAnchor: segment.fromPort ?? fromMarker.anchor,
                    toAnchor: segment.toPort ?? toMarker.anchor
                )
            }
            try validateSemanticSegment(segment, graphSegments: graphSegments)
        }

        for marker in document.stationMarkers {
            try validateIdentifier(marker.stationID, kind: "station marker")
            guard let graphStation = graphStations[marker.stationID] else {
                throw invalid(.unknownStation(marker.stationID, context: "station marker"))
            }
            guard marker.name == graphStation.name else {
                throw invalid(.stationNameMismatch(
                    stationID: marker.stationID,
                    expected: graphStation.name,
                    actual: marker.name
                ))
            }
            guard !marker.lineIDs.isEmpty,
                  Set(marker.lineIDs).isSubset(of: Set(graphStation.lineIDs)) else {
                throw invalid(.stationLinesMismatch(stationID: marker.stationID))
            }
            try validate(point: marker.anchor, context: "station \(marker.stationID) anchor", in: canvas)
            try validatePositive(marker.hitRadius, context: "station \(marker.stationID) hit radius")
            guard !marker.primitives.isEmpty else {
                throw invalid(.stationHasNoPrimitives(stationID: marker.stationID))
            }
            for (index, primitive) in marker.primitives.enumerated() {
                if case let .tick(tick) = primitive,
                   !marker.lineIDs.contains(tick.lineID) {
                    throw invalid(.stationLinesMismatch(stationID: marker.stationID))
                }
                try validate(
                    primitive: primitive,
                    context: "station \(marker.stationID) primitive \(index)",
                    in: canvas
                )
            }
        }

        for label in document.labels {
            try validateIdentifier(label.id, kind: "label")
            guard markerIDs.contains(label.stationID) else {
                throw invalid(.missingStationMarker(
                    stationID: label.stationID,
                    context: "label \(label.id)"
                ))
            }
            guard !label.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid(.emptyLabelText(labelID: label.id))
            }
            try validate(point: label.position, context: "label \(label.id)", in: canvas)
            guard label.rotationDegrees.isFinite else {
                throw invalid(.nonFiniteValue(context: "label \(label.id) rotation"))
            }
            if let associatedStationIDs = label.associatedStationIDs {
                try validateUnique(
                    associatedStationIDs,
                    kind: "label \(label.id) associated station"
                )
                for stationID in associatedStationIDs where !markerIDs.contains(stationID) {
                    throw invalid(.missingStationMarker(
                        stationID: stationID,
                        context: "label \(label.id) associated station"
                    ))
                }
            }
        }

        for route in document.routes {
            try validate(route: route, segmentsByID: segmentsByID, markerIDs: markerIDs)
        }
    }

    private func resourceURL(for region: BeckMapRegion) throws -> URL {
        let resourceName = region.rawValue
        let resourcePath = "Resources/BeckMap/v1/\(resourceName).json"
        let namedCandidates: [(subdirectory: String?, name: String)] = [
            ("BeckMap/v1", resourceName),
            ("Resources/BeckMap/v1", resourceName),
            (nil, resourceName),
        ]
        for candidate in namedCandidates {
            if let url = bundle.url(
                forResource: candidate.name,
                withExtension: "json",
                subdirectory: candidate.subdirectory
            ) {
                return url
            }
        }

        guard let resourceRoot = bundle.resourceURL else {
            throw BeckMapRepositoryError.missingResource(path: resourcePath)
        }

        let relativeCandidates = [
            "BeckMap/v1/\(resourceName).json",
            resourcePath,
        ]
        for relativePath in relativeCandidates {
            let url = resourceRoot.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let suffix = "/BeckMap/v1/\(resourceName).json"
        if let enumerator = FileManager.default.enumerator(
            at: resourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator where url.path.hasSuffix(suffix) {
                return url
            }
        }

        throw BeckMapRepositoryError.missingResource(path: resourcePath)
    }

    private func validate(path: BeckMapPathRecord, in canvas: BeckMapSize) throws {
        try validateIdentifier(path.id, kind: "path")
        guard path.commands.count >= 2 else {
            throw invalid(.invalidPathOrder(pathID: path.id, commandIndex: 0))
        }
        guard case .move = path.commands[0] else {
            throw invalid(.invalidPathOrder(pathID: path.id, commandIndex: 0))
        }

        var hasDrawableCommand = false
        for (index, command) in path.commands.enumerated() {
            switch command {
            case let .move(to):
                guard index == 0 else {
                    throw invalid(.invalidPathOrder(pathID: path.id, commandIndex: index))
                }
                try validate(point: to, context: "path \(path.id) move", in: canvas)
            case let .line(to):
                hasDrawableCommand = true
                try validate(point: to, context: "path \(path.id) line", in: canvas)
            case let .cubic(control1, control2, to):
                hasDrawableCommand = true
                try validate(point: control1, context: "path \(path.id) cubic control 1", in: canvas)
                try validate(point: control2, context: "path \(path.id) cubic control 2", in: canvas)
                try validate(point: to, context: "path \(path.id) cubic destination", in: canvas)
            case .close:
                guard hasDrawableCommand, index == path.commands.indices.last else {
                    throw invalid(.invalidPathOrder(pathID: path.id, commandIndex: index))
                }
            }
        }
        guard hasDrawableCommand else {
            throw invalid(.invalidPathOrder(pathID: path.id, commandIndex: 1))
        }
    }

    private func validateSemanticSegment(
        _ segment: BeckMapSegmentRecord,
        graphSegments: [String: TubeSegment]
    ) throws {
        if segment.id == Self.supplementalHeathrowSegmentID {
            let isExpectedSupplement = segment.lineID == .piccadilly
                && Set([segment.fromStationID, segment.toStationID]) == Set(["940GZZLUHNX", "940GZZLUHR4"])
            guard isExpectedSupplement else {
                throw invalid(.supplementalSegmentMismatch(segmentID: segment.id))
            }
            return
        }

        guard let semanticSegment = graphSegments[segment.id] else {
            throw invalid(.unknownSemanticSegment(segmentID: segment.id))
        }
        let lineMatches = semanticSegment.lineID == segment.lineID
        let stationsMatch = Set([semanticSegment.fromStationID, semanticSegment.toStationID])
            == Set([segment.fromStationID, segment.toStationID])
        guard lineMatches, stationsMatch else {
            throw invalid(.semanticSegmentMismatch(segmentID: segment.id))
        }
    }

    private func validate(
        route: BeckMapRouteRecord,
        segmentsByID: [String: BeckMapSegmentRecord],
        markerIDs: Set<String>
    ) throws {
        try validateIdentifier(route.id, kind: "route")
        guard route.stationIDs.count >= 2,
              route.segmentIDs.count == route.stationIDs.count - 1 else {
            throw invalid(.routeCardinalityMismatch(routeID: route.id))
        }
        for stationID in route.stationIDs where !markerIDs.contains(stationID) {
            throw invalid(.missingStationMarker(stationID: stationID, context: "route \(route.id)"))
        }
        for index in route.segmentIDs.indices {
            let segmentID = route.segmentIDs[index]
            guard let segment = segmentsByID[segmentID] else {
                throw invalid(.routeReferencesUnknownSegment(routeID: route.id, segmentID: segmentID))
            }
            guard segment.lineID == route.lineID else {
                throw invalid(.routeLineMismatch(routeID: route.id, segmentID: segmentID))
            }
            let adjacentStations = Set([route.stationIDs[index], route.stationIDs[index + 1]])
            let segmentStations = Set([segment.fromStationID, segment.toStationID])
            guard adjacentStations == segmentStations else {
                throw invalid(.routeAdjacencyMismatch(
                    routeID: route.id,
                    segmentID: segmentID,
                    stationIndex: index
                ))
            }
        }
    }

    private func validate(
        primitive: BeckMapStationMarkerPrimitive,
        context: String,
        in canvas: BeckMapSize
    ) throws {
        switch primitive {
        case let .connector(connector):
            try validate(point: connector.start, context: "\(context) connector start", in: canvas)
            try validate(point: connector.end, context: "\(context) connector end", in: canvas)
            try validatePositive(connector.width, context: "\(context) connector width")
        case let .walkingConnector(connector):
            try validate(point: connector.start, context: "\(context) walking connector start", in: canvas)
            try validate(point: connector.end, context: "\(context) walking connector end", in: canvas)
            try validatePositive(connector.width, context: "\(context) walking connector width")
        case let .circle(circle):
            try validate(point: circle.centre, context: "\(context) circle centre", in: canvas)
            try validatePositive(circle.radius, context: "\(context) circle radius")
            try validatePositive(circle.outlineWidth, context: "\(context) circle outline width")
        case let .tick(tick):
            try validate(point: tick.start, context: "\(context) tick start", in: canvas)
            try validate(point: tick.end, context: "\(context) tick end", in: canvas)
            try validatePositive(tick.width, context: "\(context) tick width")
        }
    }

    private func validateTranslatedCoordinates(
        of path: BeckMapPathRecord,
        by translation: BeckMapTranslation,
        segmentID: String,
        in canvas: BeckMapSize
    ) throws {
        for point in path.points {
            try validate(
                point: BeckMapPoint(x: point.x + translation.x, y: point.y + translation.y),
                context: "segment \(segmentID) translated path",
                in: canvas
            )
        }
    }

    private func validatePathEndpoints(
        of segment: BeckMapSegmentRecord,
        path: BeckMapPathRecord,
        fromAnchor: BeckMapPoint,
        toAnchor: BeckMapPoint
    ) throws {
        guard let rawStart = path.startPoint, let rawEnd = path.endPoint else {
            throw invalid(.invalidPathOrder(pathID: path.id, commandIndex: 0))
        }
        let pathStart = rawStart.translated(by: segment.translation)
        let pathEnd = rawEnd.translated(by: segment.translation)
        let expectedStart: (stationID: String, point: BeckMapPoint)
        let expectedEnd: (stationID: String, point: BeckMapPoint)
        switch segment.pathDirection {
        case .forward:
            expectedStart = (segment.fromStationID, fromAnchor)
            expectedEnd = (segment.toStationID, toAnchor)
        case .reverse:
            expectedStart = (segment.toStationID, toAnchor)
            expectedEnd = (segment.fromStationID, fromAnchor)
        }

        try validatePathEndpoint(
            pathStart,
            expected: expectedStart.point,
            endpoint: "start",
            stationID: expectedStart.stationID,
            segmentID: segment.id
        )
        try validatePathEndpoint(
            pathEnd,
            expected: expectedEnd.point,
            endpoint: "end",
            stationID: expectedEnd.stationID,
            segmentID: segment.id
        )
    }

    private func validatePathEndpoint(
        _ actual: BeckMapPoint,
        expected: BeckMapPoint,
        endpoint: String,
        stationID: String,
        segmentID: String
    ) throws {
        let tolerance = 0.5
        guard hypot(actual.x - expected.x, actual.y - expected.y) <= tolerance else {
            throw invalid(.segmentPathEndpointMismatch(
                segmentID: segmentID,
                endpoint: endpoint,
                stationID: stationID,
                expected: expected,
                actual: actual
            ))
        }
    }

    private func validate(translation: BeckMapTranslation, segmentID: String) throws {
        guard translation.x.isFinite, translation.y.isFinite else {
            throw invalid(.nonFiniteValue(context: "segment \(segmentID) translation"))
        }
    }

    private func validate(point: BeckMapPoint, context: String, in canvas: BeckMapSize) throws {
        guard point.x.isFinite, point.y.isFinite else {
            throw invalid(.nonFiniteValue(context: context))
        }
        guard (0 ... canvas.width).contains(point.x),
              (0 ... canvas.height).contains(point.y) else {
            throw invalid(.coordinateOutOfBounds(context: context, point: point))
        }
    }

    private func validatePositive(_ value: Double, context: String) throws {
        guard value.isFinite else {
            throw invalid(.nonFiniteValue(context: context))
        }
        guard value > 0 else {
            throw invalid(.nonPositiveValue(context: context, value: value))
        }
    }

    private func validateUnique(_ identifiers: [String], kind: String) throws {
        var seen: Set<String> = []
        for identifier in identifiers {
            try validateIdentifier(identifier, kind: kind)
            guard seen.insert(identifier).inserted else {
                throw invalid(.duplicateIdentifier(kind: kind, identifier: identifier))
            }
        }
    }

    private func validateIdentifier(_ identifier: String, kind: String) throws {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid(.emptyIdentifier(kind: kind))
        }
    }

    private func invalid(_ issue: BeckMapValidationIssue) -> BeckMapRepositoryError {
        .validationFailed(issue)
    }
}

enum BeckMapRepositoryError: LocalizedError, Equatable {
    case missingResource(path: String)
    case unreadableResource(path: String, reason: String)
    case decodingFailed(reason: String)
    case validationFailed(BeckMapValidationIssue)

    var errorDescription: String? {
        switch self {
        case let .missingResource(path):
            "The authored Beck map resource could not be found at \(path)."
        case let .unreadableResource(path, reason):
            "The authored Beck map resource at \(path) could not be read: \(reason)"
        case let .decodingFailed(reason):
            "The authored Beck map resource could not be decoded: \(reason)"
        case let .validationFailed(issue):
            "The authored Beck map resource failed validation: \(issue.description)"
        }
    }
}

enum BeckMapValidationIssue: Equatable, Sendable {
    case unsupportedSchema(BeckMapSchemaVersion)
    case geometryIsNotAuthored(BeckMapGeometryStatus)
    case graphSchemaMismatch(expected: Int, actual: Int)
    case invalidArtworkSize(BeckMapSize)
    case invalidStyleOrdering
    case invalidOpacity(Double)
    case emptyIdentifier(kind: String)
    case duplicateIdentifier(kind: String, identifier: String)
    case invalidPathOrder(pathID: String, commandIndex: Int)
    case coordinateOutOfBounds(context: String, point: BeckMapPoint)
    case nonFiniteValue(context: String)
    case nonPositiveValue(context: String, value: Double)
    case missingPath(segmentID: String, pathID: String)
    case segmentHasIdenticalEndpoints(segmentID: String)
    case segmentPathEndpointMismatch(
        segmentID: String,
        endpoint: String,
        stationID: String,
        expected: BeckMapPoint,
        actual: BeckMapPoint
    )
    case unknownStation(String, context: String)
    case missingStationMarker(stationID: String, context: String)
    case stationNameMismatch(stationID: String, expected: String, actual: String)
    case stationLinesMismatch(stationID: String)
    case stationHasNoPrimitives(stationID: String)
    case emptyLabelText(labelID: String)
    case unknownSemanticSegment(segmentID: String)
    case semanticSegmentMismatch(segmentID: String)
    case supplementalSegmentMismatch(segmentID: String)
    case routeCardinalityMismatch(routeID: String)
    case routeReferencesUnknownSegment(routeID: String, segmentID: String)
    case routeLineMismatch(routeID: String, segmentID: String)
    case routeAdjacencyMismatch(routeID: String, segmentID: String, stationIndex: Int)

    var description: String {
        switch self {
        case let .unsupportedSchema(version):
            "schema \(version.major).\(version.minor) is unsupported"
        case let .geometryIsNotAuthored(status):
            "geometry status is \(status.rawValue), not authored"
        case let .graphSchemaMismatch(expected, actual):
            "graph schema is \(actual), expected \(expected)"
        case let .invalidArtworkSize(size):
            "artwork size \(size.width) x \(size.height) is invalid"
        case .invalidStyleOrdering:
            "affected stroke widths must descend from outer to knockout to route and contain the base route"
        case let .invalidOpacity(opacity):
            "debug geometry opacity \(opacity) is outside 0...1"
        case let .emptyIdentifier(kind):
            "\(kind) identifier is empty"
        case let .duplicateIdentifier(kind, identifier):
            "duplicate \(kind) identifier \(identifier)"
        case let .invalidPathOrder(pathID, commandIndex):
            "path \(pathID) has an invalid command at index \(commandIndex)"
        case let .coordinateOutOfBounds(context, point):
            "\(context) coordinate (\(point.x), \(point.y)) is outside the artwork"
        case let .nonFiniteValue(context):
            "\(context) is not finite"
        case let .nonPositiveValue(context, value):
            "\(context) must be positive, found \(value)"
        case let .missingPath(segmentID, pathID):
            "segment \(segmentID) references missing path \(pathID)"
        case let .segmentHasIdenticalEndpoints(segmentID):
            "segment \(segmentID) has identical endpoints"
        case let .segmentPathEndpointMismatch(segmentID, endpoint, stationID, expected, actual):
            "segment \(segmentID) path \(endpoint) (\(actual.x), \(actual.y)) does not meet station \(stationID) anchor (\(expected.x), \(expected.y))"
        case let .unknownStation(stationID, context):
            "\(context) references unknown station \(stationID)"
        case let .missingStationMarker(stationID, context):
            "\(context) references station \(stationID) without authored marker artwork"
        case let .stationNameMismatch(stationID, expected, actual):
            "station \(stationID) is named \(actual), expected \(expected)"
        case let .stationLinesMismatch(stationID):
            "station \(stationID) declares lines absent from the semantic graph"
        case let .stationHasNoPrimitives(stationID):
            "station \(stationID) has no authored marker primitives"
        case let .emptyLabelText(labelID):
            "label \(labelID) has empty text"
        case let .unknownSemanticSegment(segmentID):
            "segment \(segmentID) is absent from the semantic graph"
        case let .semanticSegmentMismatch(segmentID):
            "segment \(segmentID) does not match its semantic graph record"
        case let .supplementalSegmentMismatch(segmentID):
            "supplemental segment \(segmentID) is not the authorised Heathrow closure"
        case let .routeCardinalityMismatch(routeID):
            "route \(routeID) must have exactly one segment per adjacent station pair"
        case let .routeReferencesUnknownSegment(routeID, segmentID):
            "route \(routeID) references unknown segment \(segmentID)"
        case let .routeLineMismatch(routeID, segmentID):
            "route \(routeID) and segment \(segmentID) are on different lines"
        case let .routeAdjacencyMismatch(routeID, segmentID, stationIndex):
            "route \(routeID) segment \(segmentID) does not join station pair \(stationIndex)"
        }
    }
}

private extension BeckMapPathRecord {
    var startPoint: BeckMapPoint? {
        guard case let .move(to) = commands.first else { return nil }
        return to
    }

    var endPoint: BeckMapPoint? {
        guard let startPoint else { return nil }
        var end = startPoint
        for command in commands.dropFirst() {
            switch command {
            case let .line(to), let .cubic(_, _, to):
                end = to
            case .close:
                end = startPoint
            case .move:
                return nil
            }
        }
        return end
    }

    var points: [BeckMapPoint] {
        commands.reduce(into: []) { points, command in
            switch command {
            case let .move(to), let .line(to):
                points.append(to)
            case let .cubic(control1, control2, to):
                points.append(contentsOf: [control1, control2, to])
            case .close:
                break
            }
        }
    }
}

private extension BeckMapPoint {
    func translated(by translation: BeckMapTranslation) -> Self {
        Self(x: x + translation.x, y: y + translation.y)
    }
}
