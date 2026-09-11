import CoreGraphics
import Foundation

struct TubeGameHub: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let representativeStationID: String
    let stationIDs: [String]
    let lineIDs: [TubeLineID]
    let point: CGPoint
}

struct TubeGameNode: Identifiable, Equatable, Sendable {
    var id: String { stationID }

    let stationID: String
    let hubID: String
    let name: String
    let lineIDs: [TubeLineID]
    let point: CGPoint
}

enum TubeGameEdgeKind: Equatable, Sendable {
    case rail(lineID: TubeLineID)
    case transfer(hubID: String)

    var lineID: TubeLineID? {
        guard case let .rail(lineID) = self else { return nil }
        return lineID
    }

    var isTransfer: Bool {
        if case .transfer = self { return true }
        return false
    }
}

struct TubeGameEdge: Identifiable, Sendable {
    let id: String
    let fromStationID: String
    let toStationID: String
    let kind: TubeGameEdgeKind
    /// The authored route geometry, kept untouched for rendering.
    let geometry: TubeGamePathGeometry
    /// Movement additionally includes short platform-port connectors so an
    /// actor always arrives at the station node before choosing its next leg.
    let movementGeometry: TubeGamePathGeometry
    /// Route tangents omit short station-port connectors added to the movement
    /// geometry, so directional choices reflect the visible railway direction.
    let fromRouteTangent: CGVector?
    let toRouteTangent: CGVector?
}

struct TubeGameDirectedEdge: Sendable {
    let edge: TubeGameEdge
    let isForward: Bool

    var edgeID: String { edge.id }
    var fromStationID: String { isForward ? edge.fromStationID : edge.toStationID }
    var toStationID: String { isForward ? edge.toStationID : edge.fromStationID }
    var lineID: TubeLineID? { edge.kind.lineID }
    var isTransfer: Bool { edge.kind.isTransfer }
    var length: CGFloat { edge.movementGeometry.totalLength }
    var playerLength: CGFloat {
        isTransfer ? edge.movementGeometry.totalLength : edge.geometry.totalLength
    }

    var outgoingTangent: CGVector {
        if isForward {
            return edge.fromRouteTangent ?? edge.movementGeometry.startTangent ?? .zero
        }
        return -(edge.toRouteTangent ?? edge.movementGeometry.endTangent ?? .zero)
    }

    var incomingTangent: CGVector {
        if isForward {
            return edge.toRouteTangent ?? edge.movementGeometry.endTangent ?? .zero
        }
        return -(edge.fromRouteTangent ?? edge.movementGeometry.startTangent ?? .zero)
    }

    func point(atDistance distance: CGFloat) -> CGPoint {
        let clampedDistance = min(length, max(0, distance))
        let geometryDistance = isForward ? clampedDistance : length - clampedDistance
        return edge.movementGeometry.point(atDistance: geometryDistance) ?? .zero
    }

    func playerPoint(atDistance distance: CGFloat) -> CGPoint {
        let clampedDistance = min(playerLength, max(0, distance))
        let geometry = isTransfer ? edge.movementGeometry : edge.geometry
        let geometryDistance = isForward
            ? clampedDistance
            : playerLength - clampedDistance
        return geometry.point(atDistance: geometryDistance) ?? .zero
    }

    func playerTangent(atDistance distance: CGFloat) -> CGVector {
        guard playerLength > 0 else { return outgoingTangent }
        let clampedDistance = min(playerLength, max(0, distance))
        let sampleRadius = min(CGFloat(1), max(CGFloat(0.01), playerLength / 10))
        let before = playerPoint(atDistance: max(0, clampedDistance - sampleRadius))
        let after = playerPoint(atDistance: min(playerLength, clampedDistance + sampleRadius))
        return CGVector.unit(from: before, to: after) ?? outgoingTangent
    }

    func playerProgress(atDistance distance: CGFloat) -> Double {
        guard playerLength > 0 else { return 1 }
        return Double(min(playerLength, max(0, distance)) / playerLength)
    }

    func tangent(atDistance distance: CGFloat) -> CGVector {
        guard length > 0 else { return outgoingTangent }
        let clampedDistance = min(length, max(0, distance))
        let sampleRadius = min(CGFloat(1), max(CGFloat(0.01), length / 10))
        let before = point(atDistance: max(0, clampedDistance - sampleRadius))
        let after = point(atDistance: min(length, clampedDistance + sampleRadius))
        return CGVector.unit(from: before, to: after) ?? outgoingTangent
    }

    func progress(atDistance distance: CGFloat) -> Double {
        guard length > 0 else { return 1 }
        return Double(min(length, max(0, distance)) / length)
    }
}

struct TubeGameRouteLeg: Equatable, Sendable {
    let edgeID: String
    let fromStationID: String
    let toStationID: String
}

struct TubeGameTrainRoute: Identifiable, Equatable, Sendable {
    let id: String
    let lineID: TubeLineID
    let stationIDs: [String]
    let legs: [TubeGameRouteLeg]
}

enum TubeGameNetworkError: LocalizedError, Equatable {
    case missingStationMarker(String)
    case missingPath(segmentID: String, pathID: String)
    case invalidSegmentGeometry(String)
    case missingRouteSegment(lineID: TubeLineID, fromStationID: String, toStationID: String)

    var errorDescription: String? {
        switch self {
        case let .missingStationMarker(stationID):
            "Track-Man cannot find artwork for station \(stationID)."
        case let .missingPath(segmentID, pathID):
            "Track-Man segment \(segmentID) cannot find path \(pathID)."
        case let .invalidSegmentGeometry(segmentID):
            "Track-Man segment \(segmentID) has no playable geometry."
        case let .missingRouteSegment(lineID, fromStationID, toStationID):
            "Track-Man route on \(lineID.displayName) cannot join \(fromStationID) to \(toStationID)."
        }
    }
}

struct TubeGameNetwork: Sendable {
    let graphGeneratedAt: String
    let artworkSize: CGSize
    let hubs: [TubeGameHub]
    let nodes: [TubeGameNode]
    let edges: [TubeGameEdge]
    let trainRoutes: [TubeGameTrainRoute]
    let lineSegmentCounts: [TubeLineID: Int]
    let lineHubIDs: [TubeLineID: Set<String>]
    let terminusHubIDs: Set<String>

    private let hubsByID: [String: TubeGameHub]
    private let nodesByID: [String: TubeGameNode]
    private let edgesByID: [String: TubeGameEdge]
    private let edgeIDsByStationID: [String: [String]]
    private let transferEdgeIDsByStationPair: [StationPair: String]
    private let hubRailAdjacency: [String: Set<String>]

    init(graph: TubeGraph, document: BeckMapDocument) throws {
        let markersByID = Dictionary(
            uniqueKeysWithValues: document.stationMarkers.map { ($0.stationID, $0) }
        )
        let pathsByID = Dictionary(uniqueKeysWithValues: document.paths.map { ($0.id, $0) })

        var builtNodes: [TubeGameNode] = []
        builtNodes.reserveCapacity(graph.stations.count)
        for station in graph.stations {
            guard let marker = markersByID[station.id] else {
                throw TubeGameNetworkError.missingStationMarker(station.id)
            }
            builtNodes.append(TubeGameNode(
                stationID: station.id,
                hubID: station.hubID ?? station.id,
                name: station.name,
                lineIDs: station.lineIDs.sorted(by: Self.lineSort),
                point: CGPoint(x: marker.anchor.x, y: marker.anchor.y)
            ))
        }
        builtNodes.sort { $0.stationID < $1.stationID }
        let builtNodesByID = Dictionary(uniqueKeysWithValues: builtNodes.map { ($0.id, $0) })

        let stationsByID = graph.stationsByID
        let groupedNodes = Dictionary(grouping: builtNodes, by: \.hubID)
        var builtHubs: [TubeGameHub] = []
        builtHubs.reserveCapacity(groupedNodes.count)
        for (hubID, hubNodes) in groupedNodes {
            let sortedNodes = hubNodes.sorted { lhs, rhs in
                let lhsLineCount = stationsByID[lhs.stationID]?.lineIDs.count ?? 0
                let rhsLineCount = stationsByID[rhs.stationID]?.lineIDs.count ?? 0
                if lhsLineCount != rhsLineCount { return lhsLineCount > rhsLineCount }
                return lhs.stationID < rhs.stationID
            }
            guard let representative = sortedNodes.first else { continue }
            let lineIDs = Array(Set(hubNodes.flatMap(\.lineIDs))).sorted(by: Self.lineSort)
            let point = CGPoint(
                x: hubNodes.map(\.point.x).reduce(0, +) / CGFloat(hubNodes.count),
                y: hubNodes.map(\.point.y).reduce(0, +) / CGFloat(hubNodes.count)
            )
            builtHubs.append(TubeGameHub(
                id: hubID,
                name: representative.name,
                representativeStationID: representative.stationID,
                stationIDs: hubNodes.map(\.stationID).sorted(),
                lineIDs: lineIDs,
                point: point
            ))
        }
        builtHubs.sort { $0.id < $1.id }

        var builtEdges: [TubeGameEdge] = []
        builtEdges.reserveCapacity(document.segments.count + graph.stations.count - builtHubs.count)
        for segment in document.segments.sorted(by: { $0.id < $1.id }) {
            guard let path = pathsByID[segment.pathID] else {
                throw TubeGameNetworkError.missingPath(segmentID: segment.id, pathID: segment.pathID)
            }
            guard let fromNode = builtNodesByID[segment.fromStationID],
                  let toNode = builtNodesByID[segment.toStationID] else {
                throw TubeGameNetworkError.missingStationMarker(
                    builtNodesByID[segment.fromStationID] == nil
                        ? segment.fromStationID
                        : segment.toStationID
                )
            }

            let routeGeometry = TubeGameGeometryBuilder.build(
                commands: path.commands,
                translation: segment.translation,
                direction: segment.pathDirection
            )
            guard routeGeometry.totalLength > 0 else {
                throw TubeGameNetworkError.invalidSegmentGeometry(segment.id)
            }

            var movementPoints = routeGeometry.points
            if let first = movementPoints.first,
               first.distance(to: fromNode.point) > 0.001 {
                movementPoints.insert(fromNode.point, at: 0)
            }
            if let last = movementPoints.last,
               last.distance(to: toNode.point) > 0.001 {
                movementPoints.append(toNode.point)
            }
            let movementGeometry = TubeGamePathGeometry(points: movementPoints)
            builtEdges.append(TubeGameEdge(
                id: segment.id,
                fromStationID: segment.fromStationID,
                toStationID: segment.toStationID,
                kind: .rail(lineID: segment.lineID),
                geometry: routeGeometry,
                movementGeometry: movementGeometry,
                fromRouteTangent: routeGeometry.startTangent,
                toRouteTangent: routeGeometry.endTangent
            ))
        }

        var builtTransferIDs: [StationPair: String] = [:]
        for hub in builtHubs where hub.stationIDs.count > 1 {
            for firstIndex in hub.stationIDs.indices {
                for secondIndex in hub.stationIDs.indices where secondIndex > firstIndex {
                    let firstID = hub.stationIDs[firstIndex]
                    let secondID = hub.stationIDs[secondIndex]
                    guard let firstNode = builtNodesByID[firstID],
                          let secondNode = builtNodesByID[secondID] else { continue }
                    let pair = StationPair(firstID, secondID)
                    let edgeID = "transfer:\(hub.id):\(pair.first):\(pair.second)"
                    let geometry = TubeGamePathGeometry(points: [firstNode.point, secondNode.point])
                    builtEdges.append(TubeGameEdge(
                        id: edgeID,
                        fromStationID: pair.first,
                        toStationID: pair.second,
                        kind: .transfer(hubID: hub.id),
                        geometry: geometry,
                        movementGeometry: geometry,
                        fromRouteTangent: geometry.startTangent,
                        toRouteTangent: geometry.endTangent
                    ))
                    builtTransferIDs[pair] = edgeID
                }
            }
        }
        builtEdges.sort { $0.id < $1.id }

        let builtEdgesByID = Dictionary(uniqueKeysWithValues: builtEdges.map { ($0.id, $0) })
        var adjacency: [String: [String]] = [:]
        for edge in builtEdges {
            adjacency[edge.fromStationID, default: []].append(edge.id)
            adjacency[edge.toStationID, default: []].append(edge.id)
        }
        adjacency = adjacency.mapValues { $0.sorted() }

        var railEdgesByPair: [LineStationPair: [TubeGameEdge]] = [:]
        for edge in builtEdges {
            guard let lineID = edge.kind.lineID else { continue }
            railEdgesByPair[LineStationPair(lineID, edge.fromStationID, edge.toStationID), default: []]
                .append(edge)
        }
        var builtRoutes: [TubeGameTrainRoute] = []
        for line in graph.lines.sorted(by: { Self.lineSort($0.id, $1.id) }) {
            for (routeIndex, stationIDs) in line.routes.enumerated() where stationIDs.count > 1 {
                var legs: [TubeGameRouteLeg] = []
                legs.reserveCapacity(stationIDs.count - 1)
                for (fromStationID, toStationID) in zip(stationIDs, stationIDs.dropFirst()) {
                    let key = LineStationPair(line.id, fromStationID, toStationID)
                    guard let edge = railEdgesByPair[key]?.sorted(by: { $0.id < $1.id }).first else {
                        throw TubeGameNetworkError.missingRouteSegment(
                            lineID: line.id,
                            fromStationID: fromStationID,
                            toStationID: toStationID
                        )
                    }
                    legs.append(TubeGameRouteLeg(
                        edgeID: edge.id,
                        fromStationID: fromStationID,
                        toStationID: toStationID
                    ))
                }
                builtRoutes.append(TubeGameTrainRoute(
                    id: "\(line.id.rawValue):route:\(routeIndex)",
                    lineID: line.id,
                    stationIDs: stationIDs,
                    legs: legs
                ))
            }
        }

        var builtHubAdjacency: [String: Set<String>] = [:]
        for edge in builtEdges where !edge.kind.isTransfer {
            guard let fromHubID = builtNodesByID[edge.fromStationID]?.hubID,
                  let toHubID = builtNodesByID[edge.toStationID]?.hubID,
                  fromHubID != toHubID else { continue }
            builtHubAdjacency[fromHubID, default: []].insert(toHubID)
            builtHubAdjacency[toHubID, default: []].insert(fromHubID)
        }

        var builtTerminusHubIDs: Set<String> = []
        for route in builtRoutes {
            guard let firstStationID = route.stationIDs.first,
                  let lastStationID = route.stationIDs.last,
                  firstStationID != lastStationID else { continue }
            if let firstHubID = builtNodesByID[firstStationID]?.hubID {
                builtTerminusHubIDs.insert(firstHubID)
            }
            if let lastHubID = builtNodesByID[lastStationID]?.hubID {
                builtTerminusHubIDs.insert(lastHubID)
            }
        }

        graphGeneratedAt = graph.generatedAt
        artworkSize = CGSize(width: document.artworkSize.width, height: document.artworkSize.height)
        hubs = builtHubs
        nodes = builtNodes
        edges = builtEdges
        trainRoutes = builtRoutes
        lineSegmentCounts = Dictionary(uniqueKeysWithValues: graph.lines.map { ($0.id, $0.segmentIDs.count) })
        lineHubIDs = Dictionary(uniqueKeysWithValues: graph.lines.map { line in
            (
                line.id,
                Set(builtHubs.lazy.filter { $0.lineIDs.contains(line.id) }.map(\.id))
            )
        })
        terminusHubIDs = builtTerminusHubIDs
        hubsByID = Dictionary(uniqueKeysWithValues: builtHubs.map { ($0.id, $0) })
        nodesByID = builtNodesByID
        edgesByID = builtEdgesByID
        edgeIDsByStationID = adjacency
        transferEdgeIDsByStationPair = builtTransferIDs
        hubRailAdjacency = builtHubAdjacency
    }

    var collectibleHubCount: Int { hubs.count }

    func hub(id: String) -> TubeGameHub? { hubsByID[id] }

    func node(stationID: String) -> TubeGameNode? { nodesByID[stationID] }

    func edge(id: String) -> TubeGameEdge? { edgesByID[id] }

    func directedEdge(edgeID: String, fromStationID: String) -> TubeGameDirectedEdge? {
        guard let edge = edgesByID[edgeID] else { return nil }
        if edge.fromStationID == fromStationID {
            return TubeGameDirectedEdge(edge: edge, isForward: true)
        }
        if edge.toStationID == fromStationID {
            return TubeGameDirectedEdge(edge: edge, isForward: false)
        }
        return nil
    }

    func railConnections(fromHubID hubID: String) -> [TubeGameDirectedEdge] {
        guard let hub = hubsByID[hubID] else { return [] }
        return hub.stationIDs.flatMap { stationID in
            (edgeIDsByStationID[stationID] ?? []).compactMap { edgeID in
                guard let directed = directedEdge(edgeID: edgeID, fromStationID: stationID),
                      !directed.isTransfer else { return nil }
                return directed
            }
        }.sorted {
            if $0.edgeID != $1.edgeID { return $0.edgeID < $1.edgeID }
            return $0.fromStationID < $1.fromStationID
        }
    }

    func transferConnection(
        fromStationID: String,
        toStationID: String
    ) -> TubeGameDirectedEdge? {
        guard fromStationID != toStationID,
              let edgeID = transferEdgeIDsByStationPair[StationPair(fromStationID, toStationID)] else {
            return nil
        }
        return directedEdge(edgeID: edgeID, fromStationID: fromStationID)
    }

    /// Bridges only the physical gap between the player's current platform
    /// point and the selected rail. Rail traversal itself stays on the
    /// authored line geometry, so arriving at an interchange never detours via
    /// a logical station anchor merely to visit another roundel.
    func stationTransition(
        fromStationID: String,
        position: CGPoint,
        to rail: TubeGameDirectedEdge
    ) -> TubeGameDirectedEdge? {
        guard let fromNode = nodesByID[fromStationID],
              let toNode = nodesByID[rail.fromStationID],
              fromNode.hubID == toNode.hubID else {
            return nil
        }
        let destination = rail.playerPoint(atDistance: 0)
        guard position.distance(to: destination) > 0.001 else { return nil }

        let geometry = TubeGamePathGeometry(points: [position, destination])
        let edge = TubeGameEdge(
            id: "station-transition:\(fromNode.hubID):\(fromStationID):\(rail.edgeID)",
            fromStationID: fromStationID,
            toStationID: rail.fromStationID,
            kind: .transfer(hubID: fromNode.hubID),
            geometry: geometry,
            movementGeometry: geometry,
            fromRouteTangent: geometry.startTangent,
            toRouteTangent: geometry.endTangent
        )
        return TubeGameDirectedEdge(edge: edge, isForward: true)
    }

    func routes(for lineID: TubeLineID) -> [TubeGameTrainRoute] {
        trainRoutes.filter { $0.lineID == lineID }
    }

    func shortestHubHopDistances(from startHubID: String) -> [String: Int] {
        guard hubsByID[startHubID] != nil else { return [:] }
        var distances = [startHubID: 0]
        var queue = [startHubID]
        var queueIndex = 0
        while queueIndex < queue.count {
            let hubID = queue[queueIndex]
            queueIndex += 1
            let nextDistance = (distances[hubID] ?? 0) + 1
            for neighbour in (hubRailAdjacency[hubID] ?? []).sorted() where distances[neighbour] == nil {
                distances[neighbour] = nextDistance
                queue.append(neighbour)
            }
        }
        return distances
    }

    private static func lineSort(_ lhs: TubeLineID, _ rhs: TubeLineID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct StationPair: Hashable, Sendable {
    let first: String
    let second: String

    init(_ lhs: String, _ rhs: String) {
        first = min(lhs, rhs)
        second = max(lhs, rhs)
    }
}

private struct LineStationPair: Hashable, Sendable {
    let lineID: TubeLineID
    let stations: StationPair

    init(_ lineID: TubeLineID, _ firstStationID: String, _ secondStationID: String) {
        self.lineID = lineID
        stations = StationPair(firstStationID, secondStationID)
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}

private extension CGVector {
    static prefix func - (vector: Self) -> Self {
        Self(dx: -vector.dx, dy: -vector.dy)
    }

    static func unit(from start: CGPoint, to end: CGPoint) -> Self? {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = hypot(deltaX, deltaY)
        guard length > 0 else { return nil }
        return Self(dx: deltaX / length, dy: deltaY / length)
    }
}
