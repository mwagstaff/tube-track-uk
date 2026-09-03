import CoreGraphics
import Foundation

struct TubeGameTrainSimulation: Sendable {
    private let network: TubeGameNetwork
    private let configuration: TubeGameConfiguration
    private let routesByID: [String: RouteMetrics]
    private(set) var states: [TrainState]

    init(
        network: TubeGameNetwork,
        seed: UInt64,
        startHubID: String,
        configuration: TubeGameConfiguration
    ) {
        self.network = network
        self.configuration = configuration

        let metrics = network.trainRoutes.compactMap { route in
            RouteMetrics(route: route, network: network)
        }
        routesByID = Dictionary(uniqueKeysWithValues: metrics.map { ($0.route.id, $0) })

        let hopDistances = network.shortestHubHopDistances(from: startHubID)
        var generator = SplitMix64(seed: seed)
        var builtStates: [TrainState] = []
        for lineID in TubeLineID.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let quota = Self.trainQuota(forSegmentCount: network.lineSegmentCounts[lineID] ?? 0)
            guard quota > 0 else { continue }
            var lineRoutes = metrics.filter { $0.route.lineID == lineID }
            guard !lineRoutes.isEmpty else { continue }
            lineRoutes.shuffle(using: &generator)

            for trainIndex in 0 ..< quota {
                let routeMetrics = lineRoutes[trainIndex % lineRoutes.count]
                let desiredFraction = min(
                    0.9,
                    max(
                        0.1,
                        Double(trainIndex + 1) / Double(quota + 1)
                            + generator.nextDouble(in: -0.06 ... 0.06)
                    )
                )
                guard let placement = routeMetrics.placement(
                    nearFraction: desiredFraction,
                    minimumHubHops: 8,
                    hopDistances: hopDistances,
                    network: network,
                    generator: &generator
                ) else { continue }
                let fallbackDirection = trainIndex.isMultiple(of: 2) ? 1 : -1

                builtStates.append(TrainState(
                    id: "train:\(lineID.rawValue):\(trainIndex)",
                    routeID: routeMetrics.route.id,
                    legIndex: placement.legIndex,
                    distanceOnLeg: placement.distanceOnLeg,
                    direction: routeMetrics.directionAwayFromStart(
                        at: placement.legIndex,
                        hopDistances: hopDistances,
                        network: network,
                        fallback: fallbackDirection
                    ),
                    dwellRemaining: 0
                ))
            }
        }
        states = builtStates.sorted { $0.id < $1.id }
    }

    static func trainQuota(forSegmentCount segmentCount: Int) -> Int {
        switch segmentCount {
        case ...0:
            0
        case 1 ..< 30:
            1
        case 30 ..< 60:
            2
        default:
            3
        }
    }

    static func totalTrainQuota(in network: TubeGameNetwork) -> Int {
        network.lineSegmentCounts.values.reduce(0) {
            $0 + trainQuota(forSegmentCount: $1)
        }
    }

    mutating func advance(by deltaTime: TimeInterval) {
        guard deltaTime.isFinite, deltaTime > 0, configuration.trainSpeed > 0 else { return }

        for stateIndex in states.indices {
            var remainingTime = deltaTime
            var safetyCounter = 0
            while remainingTime > 0, safetyCounter < 32 {
                safetyCounter += 1
                if states[stateIndex].dwellRemaining > 0 {
                    let dwell = min(remainingTime, states[stateIndex].dwellRemaining)
                    states[stateIndex].dwellRemaining -= dwell
                    remainingTime -= dwell
                    if remainingTime <= 0 { break }
                }

                guard let route = routesByID[states[stateIndex].routeID],
                      route.legs.indices.contains(states[stateIndex].legIndex) else {
                    break
                }
                let leg = route.legs[states[stateIndex].legIndex]
                let distanceToStation = states[stateIndex].direction > 0
                    ? leg.length - states[stateIndex].distanceOnLeg
                    : states[stateIndex].distanceOnLeg
                let travelDistance = configuration.trainSpeed * CGFloat(remainingTime)

                if travelDistance + 0.000_001 < distanceToStation {
                    states[stateIndex].distanceOnLeg += CGFloat(states[stateIndex].direction) * travelDistance
                    remainingTime = 0
                    continue
                }

                let travelTime = distanceToStation / configuration.trainSpeed
                remainingTime = max(0, remainingTime - TimeInterval(travelTime))
                let reachedTerminus: Bool
                if states[stateIndex].direction > 0 {
                    states[stateIndex].distanceOnLeg = leg.length
                    reachedTerminus = states[stateIndex].legIndex == route.legs.count - 1
                    if reachedTerminus {
                        states[stateIndex].direction = -1
                    } else {
                        states[stateIndex].legIndex += 1
                        states[stateIndex].distanceOnLeg = 0
                    }
                } else {
                    states[stateIndex].distanceOnLeg = 0
                    reachedTerminus = states[stateIndex].legIndex == 0
                    if reachedTerminus {
                        states[stateIndex].direction = 1
                    } else {
                        states[stateIndex].legIndex -= 1
                        states[stateIndex].distanceOnLeg = route.legs[states[stateIndex].legIndex].length
                    }
                }
                states[stateIndex].dwellRemaining = reachedTerminus
                    ? configuration.trainTerminusDwell
                    : configuration.trainStationDwell
            }
        }
    }

    var snapshots: [TubeGameTrainSnapshot] {
        states.compactMap { state in
            guard let route = routesByID[state.routeID],
                  route.legs.indices.contains(state.legIndex) else { return nil }
            let leg = route.legs[state.legIndex]
            let directed = leg.directedEdge
            let heading = state.direction > 0
                ? directed.tangent(atDistance: state.distanceOnLeg)
                : -directed.tangent(atDistance: state.distanceOnLeg)
            return TubeGameTrainSnapshot(
                id: state.id,
                lineID: route.route.lineID,
                routeID: route.route.id,
                position: directed.point(atDistance: state.distanceOnLeg),
                heading: heading,
                edgeID: directed.edgeID,
                edgeProgress: directed.progress(atDistance: state.distanceOnLeg)
            )
        }.sorted { $0.id < $1.id }
    }
}

extension TubeGameTrainSimulation {
    struct TrainState: Equatable, Sendable {
        let id: String
        let routeID: String
        var legIndex: Int
        var distanceOnLeg: CGFloat
        var direction: Int
        var dwellRemaining: TimeInterval
    }
}

private extension TubeGameTrainSimulation {
    struct RouteLegMetrics: Sendable {
        let leg: TubeGameRouteLeg
        let directedEdge: TubeGameDirectedEdge
        let length: CGFloat
    }

    struct RouteMetrics: Sendable {
        let route: TubeGameTrainRoute
        let legs: [RouteLegMetrics]
        let cumulativeLengths: [CGFloat]
        let totalLength: CGFloat

        init?(route: TubeGameTrainRoute, network: TubeGameNetwork) {
            let legs = route.legs.compactMap { leg -> RouteLegMetrics? in
                guard let directed = network.directedEdge(
                    edgeID: leg.edgeID,
                    fromStationID: leg.fromStationID
                ), directed.length > 0 else { return nil }
                return RouteLegMetrics(leg: leg, directedEdge: directed, length: directed.length)
            }
            guard legs.count == route.legs.count, !legs.isEmpty else { return nil }
            var cumulativeLengths: [CGFloat] = [0]
            cumulativeLengths.reserveCapacity(legs.count + 1)
            for leg in legs {
                cumulativeLengths.append((cumulativeLengths.last ?? 0) + leg.length)
            }
            guard let totalLength = cumulativeLengths.last, totalLength > 0 else { return nil }
            self.route = route
            self.legs = legs
            self.cumulativeLengths = cumulativeLengths
            self.totalLength = totalLength
        }

        func placement(
            nearFraction fraction: Double,
            minimumHubHops: Int,
            hopDistances: [String: Int],
            network: TubeGameNetwork,
            generator: inout SplitMix64
        ) -> Placement? {
            let targetDistance = totalLength * CGFloat(min(1, max(0, fraction)))
            let eligibleIndices = legs.indices.filter { index in
                let leg = legs[index].leg
                guard let fromHubID = network.node(stationID: leg.fromStationID)?.hubID,
                      let toHubID = network.node(stationID: leg.toStationID)?.hubID else {
                    return false
                }
                return (hopDistances[fromHubID] ?? .max) >= minimumHubHops
                    && (hopDistances[toHubID] ?? .max) >= minimumHubHops
            }
            let candidateIndices = eligibleIndices.isEmpty ? Array(legs.indices) : eligibleIndices
            guard let legIndex = candidateIndices.min(by: { lhs, rhs in
                let lhsMidpoint = (cumulativeLengths[lhs] + cumulativeLengths[lhs + 1]) / 2
                let rhsMidpoint = (cumulativeLengths[rhs] + cumulativeLengths[rhs + 1]) / 2
                let lhsDistance = abs(lhsMidpoint - targetDistance)
                let rhsDistance = abs(rhsMidpoint - targetDistance)
                if abs(lhsDistance - rhsDistance) > 0.000_001 {
                    return lhsDistance < rhsDistance
                }
                return lhs < rhs
            }) else { return nil }

            let legStart = cumulativeLengths[legIndex]
            let legLength = legs[legIndex].length
            let idealProgress = Double((targetDistance - legStart) / legLength)
            let localProgress: Double
            if (0 ... 1).contains(idealProgress) {
                localProgress = min(0.85, max(0.15, idealProgress))
            } else {
                localProgress = min(0.75, max(0.25, 0.5 + generator.nextDouble(in: -0.12 ... 0.12)))
            }
            return Placement(
                legIndex: legIndex,
                distanceOnLeg: legLength * CGFloat(localProgress)
            )
        }

        func directionAwayFromStart(
            at legIndex: Int,
            hopDistances: [String: Int],
            network: TubeGameNetwork,
            fallback: Int
        ) -> Int {
            guard legs.indices.contains(legIndex) else { return fallback }
            let leg = legs[legIndex].leg
            guard let fromHubID = network.node(stationID: leg.fromStationID)?.hubID,
                  let toHubID = network.node(stationID: leg.toStationID)?.hubID
            else { return fallback }

            let fromDistance = hopDistances[fromHubID] ?? .max
            let toDistance = hopDistances[toHubID] ?? .max
            if toDistance > fromDistance { return 1 }
            if fromDistance > toDistance { return -1 }
            return fallback
        }
    }

    struct Placement: Sendable {
        let legIndex: Int
        let distanceOnLeg: CGFloat
    }
}

private struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(UInt64(1) << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

private extension CGVector {
    static prefix func - (vector: Self) -> Self {
        Self(dx: -vector.dx, dy: -vector.dy)
    }
}
