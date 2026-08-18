import Foundation

/// A rendered schematic centreline made from straight runs and genuine cubic
/// Bézier fillets. Direction changes never appear as line-to-line vertices.
struct RoundedSchematicPath: Equatable, Sendable {
    enum Element: Equatable, Sendable {
        case line(to: SchematicPoint)
        case curve(to: SchematicPoint, control1: SchematicPoint, control2: SchematicPoint)
    }

    let start: SchematicPoint
    let elements: [Element]
    let sampledPoints: [SchematicPoint]

    init?(points: [SchematicPoint], preferredCornerRadius: Double, samplesPerCurve: Int = 12) {
        let points = points.removingConsecutiveDuplicates
        guard let first = points.first else { return nil }
        guard points.count > 1 else {
            self.init(start: first, elements: [], samplesPerCurve: samplesPerCurve)
            return
        }

        let fillets = points.indices.map { index -> SchematicFillet? in
            guard index > points.startIndex, index < points.index(before: points.endIndex) else { return nil }
            return SchematicFillet(
                incomingPoint: points[index - 1],
                corner: points[index],
                outgoingPoint: points[index + 1],
                preferredRadius: preferredCornerRadius
            )
        }

        var elements: [Element] = []
        for index in 1 ..< points.count - 1 {
            if let fillet = fillets[index] {
                elements.append(.line(to: fillet.entry))
                elements.append(.curve(
                    to: fillet.exit,
                    control1: fillet.control1,
                    control2: fillet.control2
                ))
            } else {
                elements.append(.line(to: points[index]))
            }
        }
        if let last = points.last {
            elements.append(.line(to: last))
        }
        self.init(start: first, elements: elements, samplesPerCurve: samplesPerCurve)
    }

    init(start: SchematicPoint, elements: [Element], samplesPerCurve: Int = 12) {
        self.start = start
        self.elements = elements
        self.sampledPoints = Self.sample(start: start, elements: elements, samplesPerCurve: samplesPerCurve)
    }

    static func cubic(
        from start: SchematicPoint,
        to end: SchematicPoint,
        control1: SchematicPoint,
        control2: SchematicPoint,
        samplesPerCurve: Int = 12
    ) -> Self {
        Self(
            start: start,
            elements: [.curve(to: end, control1: control1, control2: control2)],
            samplesPerCurve: samplesPerCurve
        )
    }

    func translated(by translation: SchematicPoint) -> Self {
        Self(
            start: start + translation,
            elements: elements.map { element in
                switch element {
                case let .line(to):
                    .line(to: to + translation)
                case let .curve(to, control1, control2):
                    .curve(
                        to: to + translation,
                        control1: control1 + translation,
                        control2: control2 + translation
                    )
                }
            }
        )
    }

    func reversed() -> Self {
        struct Piece {
            let start: SchematicPoint
            let end: SchematicPoint
            let control1: SchematicPoint?
            let control2: SchematicPoint?
        }

        var pieces: [Piece] = []
        var current = start
        for element in elements {
            switch element {
            case let .line(to):
                pieces.append(Piece(start: current, end: to, control1: nil, control2: nil))
                current = to
            case let .curve(to, control1, control2):
                pieces.append(Piece(start: current, end: to, control1: control1, control2: control2))
                current = to
            }
        }

        let reversedElements = pieces.reversed().map { piece -> Element in
            if let control1 = piece.control1, let control2 = piece.control2 {
                return .curve(to: piece.start, control1: control2, control2: control1)
            }
            return .line(to: piece.start)
        }
        return Self(start: current, elements: reversedElements)
    }

    private static func sample(
        start: SchematicPoint,
        elements: [Element],
        samplesPerCurve: Int
    ) -> [SchematicPoint] {
        var result = [start]
        var current = start
        for element in elements {
            switch element {
            case let .line(to):
                result.append(to)
                current = to
            case let .curve(to, control1, control2):
                let sampleCount = max(4, samplesPerCurve)
                for sample in 1 ... sampleCount {
                    let t = Double(sample) / Double(sampleCount)
                    result.append(cubicPoint(
                        from: current,
                        to: to,
                        control1: control1,
                        control2: control2,
                        t: t
                    ))
                }
                current = to
            }
        }
        return result
    }

    private static func cubicPoint(
        from start: SchematicPoint,
        to end: SchematicPoint,
        control1: SchematicPoint,
        control2: SchematicPoint,
        t: Double
    ) -> SchematicPoint {
        let oneMinusT = 1 - t
        let startWeight = oneMinusT * oneMinusT * oneMinusT
        let firstControlWeight = 3 * oneMinusT * oneMinusT * t
        let secondControlWeight = 3 * oneMinusT * t * t
        let endWeight = t * t * t
        return SchematicPoint(
            x: start.x * startWeight
                + control1.x * firstControlWeight
                + control2.x * secondControlWeight
                + end.x * endWeight,
            y: start.y * startWeight
                + control1.y * firstControlWeight
                + control2.y * secondControlWeight
                + end.y * endWeight
        )
    }
}

/// Circular fillet geometry represented by a cubic Bézier. The handles are
/// tangent to the incoming and outgoing straight runs. Its radius is clamped
/// so two neighbouring fillets cannot consume a whole route leg.
struct SchematicFillet: Equatable, Sendable {
    let entry: SchematicPoint
    let exit: SchematicPoint
    let control1: SchematicPoint
    let control2: SchematicPoint
    let effectiveRadius: Double
    let tangentDistance: Double

    init?(
        incomingPoint: SchematicPoint,
        corner: SchematicPoint,
        outgoingPoint: SchematicPoint,
        preferredRadius: Double
    ) {
        let incomingVector = corner - incomingPoint
        let outgoingVector = outgoingPoint - corner
        let incomingLength = incomingVector.length
        let outgoingLength = outgoingVector.length
        guard incomingLength > 0.001, outgoingLength > 0.001 else { return nil }

        let incomingDirection = incomingVector / incomingLength
        let outgoingDirection = outgoingVector / outgoingLength
        let cosine = min(1, max(-1, incomingDirection.dot(outgoingDirection)))
        let turnAngle = acos(cosine)
        guard turnAngle > 0.001, turnAngle < .pi - 0.001 else { return nil }

        let tangentFactor = tan(turnAngle / 2)
        guard tangentFactor > 0.001 else { return nil }
        let preferredTangentDistance = max(0, preferredRadius) * tangentFactor
        let tangentDistance = min(
            preferredTangentDistance,
            incomingLength * 0.45,
            outgoingLength * 0.45
        )
        guard tangentDistance > 0.001 else { return nil }

        let effectiveRadius = tangentDistance / tangentFactor
        let handleLength = 4 / 3 * tan(turnAngle / 4) * effectiveRadius
        let entry = corner - incomingDirection * tangentDistance
        let exit = corner + outgoingDirection * tangentDistance

        self.entry = entry
        self.exit = exit
        self.control1 = entry + incomingDirection * handleLength
        self.control2 = exit - outgoingDirection * handleLength
        self.effectiveRadius = effectiveRadius
        self.tangentDistance = tangentDistance
    }
}

struct SchematicRouteConnector: Sendable {
    let lineID: TubeLineID
    let incomingSegmentID: String
    let outgoingSegmentID: String
    let path: RoundedSchematicPath
}

/// Map-only route geometry for a service pattern which TfL's adjacent-stop
/// pairs do not express. It is intentionally excluded from graph topology.
struct SchematicSupplementaryRoute: Sendable {
    let lineID: TubeLineID
    let path: RoundedSchematicPath
}

/// Converts the graph's layout vertices into reusable render geometry.
///
/// All coloured siblings on a shared station pair use the same rounded master
/// path. Only a translation is applied for their lane, so their curves cannot
/// acquire different radii or control handles.
struct SchematicNetworkGeometry: Sendable {
    let segmentPaths: [String: RoundedSchematicPath]
    let connectors: [SchematicRouteConnector]
    let laneTranslations: [String: SchematicPoint]
    /// Untrimmed route-aligned endpoints, keyed by segment then station. The
    /// renderer uses these as platform positions for interchange bars.
    let renderedStationPoints: [String: [String: SchematicPoint]]
    let supplementaryRoutes: [SchematicSupplementaryRoute]

    init(
        graph: TubeGraph,
        laneOffsets: [String: Double],
        laneTranslationOverrides: [String: SchematicPoint] = [:],
        preferredCornerRadius: Double
    ) {
        let segmentLookup = Dictionary(uniqueKeysWithValues: graph.segments.map { segment in
            (Self.segmentKey(lineID: segment.lineID, stationA: segment.fromStationID, stationB: segment.toStationID), segment)
        })

        struct PendingConnector {
            let lineID: TubeLineID
            let incomingSegmentID: String
            let outgoingSegmentID: String
            let fillet: SchematicFillet
        }

        var endpointTrims: [String: [String: Double]] = [:]
        var pendingConnectors: [PendingConnector] = []
        var connectorKeys: Set<String> = []

        for line in graph.lines {
            for route in line.routes where route.count >= 3 {
                for index in 1 ..< route.count - 1 {
                    let previousStationID = route[index - 1]
                    let stationID = route[index]
                    let nextStationID = route[index + 1]
                    guard
                        let incomingSegment = segmentLookup[Self.segmentKey(
                            lineID: line.id,
                            stationA: previousStationID,
                            stationB: stationID
                        )],
                        let outgoingSegment = segmentLookup[Self.segmentKey(
                            lineID: line.id,
                            stationA: stationID,
                            stationB: nextStationID
                        )]
                    else { continue }

                    let incomingPoints = Self.orientedPoints(
                        for: incomingSegment,
                        from: previousStationID,
                        to: stationID
                    )
                    let outgoingPoints = Self.orientedPoints(
                        for: outgoingSegment,
                        from: stationID,
                        to: nextStationID
                    )
                    guard let corner = incomingPoints.last,
                          let outgoingCorner = outgoingPoints.first,
                          corner.distance(to: outgoingCorner) < 0.01,
                          let incomingPoint = incomingPoints.dropLast().last,
                          let outgoingPoint = outgoingPoints.dropFirst().first,
                          let fillet = SchematicFillet(
                            incomingPoint: incomingPoint,
                            corner: corner,
                            outgoingPoint: outgoingPoint,
                            preferredRadius: preferredCornerRadius
                          ) else { continue }

                    let forwardKey = "\(previousStationID):\(stationID):\(nextStationID)"
                    let reverseKey = "\(nextStationID):\(stationID):\(previousStationID)"
                    let connectorKey = "\(line.id.rawValue):\(min(forwardKey, reverseKey))"
                    guard connectorKeys.insert(connectorKey).inserted else { continue }

                    endpointTrims[incomingSegment.id, default: [:]][stationID] = max(
                        endpointTrims[incomingSegment.id]?[stationID] ?? 0,
                        fillet.tangentDistance
                    )
                    endpointTrims[outgoingSegment.id, default: [:]][stationID] = max(
                        endpointTrims[outgoingSegment.id]?[stationID] ?? 0,
                        fillet.tangentDistance
                    )
                    pendingConnectors.append(PendingConnector(
                        lineID: line.id,
                        incomingSegmentID: incomingSegment.id,
                        outgoingSegmentID: outgoingSegment.id,
                        fillet: fillet
                    ))
                }
            }
        }

        let groups = Dictionary(grouping: graph.segments) { segment in
            Self.stationPairKey(segment.fromStationID, segment.toStationID)
        }
        var segmentPaths: [String: RoundedSchematicPath] = [:]
        var translations: [String: SchematicPoint] = [:]
        var renderedStationPoints: [String: [String: SchematicPoint]] = [:]

        for siblings in groups.values {
            guard let representative = siblings.sorted(by: { $0.lineID.rawValue < $1.lineID.rawValue }).first else { continue }
            let canonicalStationIDs = [representative.fromStationID, representative.toStationID].sorted()
            guard canonicalStationIDs.count == 2 else { continue }
            let canonicalStartID = canonicalStationIDs[0]
            let canonicalEndID = canonicalStationIDs[1]
            var masterPoints = Self.orientedPoints(
                for: representative,
                from: canonicalStartID,
                to: canonicalEndID
            )
            guard let untrimmedStart = masterPoints.first,
                  let untrimmedEnd = masterPoints.last else { continue }

            let startTrim = siblings.map { endpointTrims[$0.id]?[canonicalStartID] ?? 0 }.max() ?? 0
            let endTrim = siblings.map { endpointTrims[$0.id]?[canonicalEndID] ?? 0 }.max() ?? 0
            masterPoints = Self.trimmingEndpoints(masterPoints, startBy: startTrim, endBy: endTrim)
            guard let masterPath = RoundedSchematicPath(
                points: masterPoints,
                preferredCornerRadius: preferredCornerRadius
            ), let first = masterPoints.first, let last = masterPoints.last else { continue }

            let direction = last - first
            let directionLength = max(1, direction.length)
            let unitNormal = SchematicPoint(x: -direction.y / directionLength, y: direction.x / directionLength)

            for sibling in siblings {
                let laneTranslation = laneTranslationOverrides[sibling.id]
                    ?? unitNormal * (laneOffsets[sibling.id] ?? 0)
                translations[sibling.id] = laneTranslation
                let orientedMaster = sibling.fromStationID == canonicalStartID ? masterPath : masterPath.reversed()
                segmentPaths[sibling.id] = orientedMaster.translated(by: laneTranslation)
                renderedStationPoints[sibling.id] = [
                    canonicalStartID: untrimmedStart + laneTranslation,
                    canonicalEndID: untrimmedEnd + laneTranslation,
                ]
            }
        }

        let connectors = pendingConnectors.map { connector in
            let incomingTranslation = translations[connector.incomingSegmentID] ?? .zero
            let outgoingTranslation = translations[connector.outgoingSegmentID] ?? .zero
            return SchematicRouteConnector(
                lineID: connector.lineID,
                incomingSegmentID: connector.incomingSegmentID,
                outgoingSegmentID: connector.outgoingSegmentID,
                path: .cubic(
                    from: connector.fillet.entry + incomingTranslation,
                    to: connector.fillet.exit + outgoingTranslation,
                    control1: connector.fillet.control1 + incomingTranslation,
                    control2: connector.fillet.control2 + outgoingTranslation
                )
            )
        }

        self.segmentPaths = segmentPaths
        self.connectors = connectors
        self.laneTranslations = translations
        self.renderedStationPoints = renderedStationPoints

        // The official diagram closes the Terminal 4 service loop. TfL's stop
        // sequences expose only the two branches through Terminals 2 & 3, so
        // close it visually without adding a navigable or disruptable edge.
        if let terminal5 = graph.stationsByID["940GZZLUHR5"]?.schematicPoint,
           let terminal4 = graph.stationsByID["940GZZLUHR4"]?.schematicPoint,
           let loopPath = RoundedSchematicPath(
               points: [terminal5, terminal4],
               preferredCornerRadius: preferredCornerRadius
           ) {
            self.supplementaryRoutes = [
                SchematicSupplementaryRoute(lineID: .piccadilly, path: loopPath),
            ]
        } else {
            self.supplementaryRoutes = []
        }
    }

    private static func trimmingEndpoints(
        _ points: [SchematicPoint],
        startBy startTrim: Double,
        endBy endTrim: Double
    ) -> [SchematicPoint] {
        guard points.count >= 2 else { return points }
        var result = points
        let firstLeg = result[1] - result[0]
        let lastLeg = result[result.count - 1] - result[result.count - 2]
        let firstLength = firstLeg.length
        let lastLength = lastLeg.length

        if firstLength > 0.001 {
            let appliedStartTrim = min(max(0, startTrim), firstLength * 0.45)
            result[0] = result[0] + firstLeg / firstLength * appliedStartTrim
        }
        if lastLength > 0.001 {
            let appliedEndTrim = min(max(0, endTrim), lastLength * 0.45)
            result[result.count - 1] = result[result.count - 1] - lastLeg / lastLength * appliedEndTrim
        }
        return result
    }

    private static func orientedPoints(
        for segment: TubeSegment,
        from stationID: String,
        to _: String
    ) -> [SchematicPoint] {
        segment.fromStationID == stationID ? segment.schematicPoints : Array(segment.schematicPoints.reversed())
    }

    private static func segmentKey(lineID: TubeLineID, stationA: String, stationB: String) -> String {
        "\(lineID.rawValue):\(stationPairKey(stationA, stationB))"
    }

    private static func stationPairKey(_ stationA: String, _ stationB: String) -> String {
        [stationA, stationB].sorted().joined(separator: ":")
    }
}

private extension Array where Element == SchematicPoint {
    var removingConsecutiveDuplicates: [SchematicPoint] {
        reduce(into: []) { result, point in
            guard result.last != point else { return }
            result.append(point)
        }
    }
}

private extension SchematicPoint {
    static let zero = SchematicPoint(x: 0, y: 0)

    var length: Double { hypot(x, y) }

    func distance(to other: Self) -> Double {
        (self - other).length
    }

    func dot(_ other: Self) -> Double {
        x * other.x + y * other.y
    }

    static func + (left: Self, right: Self) -> Self {
        Self(x: left.x + right.x, y: left.y + right.y)
    }

    static func - (left: Self, right: Self) -> Self {
        Self(x: left.x - right.x, y: left.y - right.y)
    }

    static func * (left: Self, right: Double) -> Self {
        Self(x: left.x * right, y: left.y * right)
    }

    static func / (left: Self, right: Double) -> Self {
        Self(x: left.x / right, y: left.y / right)
    }
}
